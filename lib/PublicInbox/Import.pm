# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# git fast-import-based ssoma-mda MDA replacement
# This is only ever run by public-inbox-mda, public-inbox-learn
# and public-inbox-watch. Not the WWW or NNTP code which only
# requires read-only access.
package PublicInbox::Import;
use strict;
use parent qw(PublicInbox::Lock);
use v5.10.1;
use PublicInbox::Spawn qw(run_die popen_rd);
use PublicInbox::MID qw(mids mid2path);
use PublicInbox::Address;
use PublicInbox::Smsg;
use PublicInbox::MsgTime qw(msg_datestamp);
use PublicInbox::ContentHash qw(content_digest);
use PublicInbox::MDA;
use PublicInbox::Eml;
use POSIX qw(strftime);

sub default_branch () {
	state $default_branch = do {
		my $r = popen_rd([qw(git config --global init.defaultBranch)],
				 { GIT_CONFIG => undef });
		chomp(my $h = <$r> // '');
		close $r;
		$h eq '' ? 'refs/heads/master' : "refs/heads/$h";
	}
}

sub new {
	# we can't change arg order, this is documented in POD
	# and external projects may rely on it:
	my ($class, $git, $name, $email, $ibx) = @_;
	my $ref;
	if ($ibx) {
		$ref = $ibx->{ref_head};
		$name //= $ibx->{name};
		$email //= $ibx->{-primary_address};
		$git //= $ibx->git;
	}
	bless {
		git => $git,
		ident => "$name <$email>",
		mark => 1,
		ref => $ref // default_branch,
		ibx => $ibx,
		path_type => '2/38', # or 'v2'
		lock_path => "$git->{git_dir}/ssoma.lock", # v2 changes this
		bytes_added => 0,
	}, $class
}

# idempotent start function
sub gfi_start {
	my ($self) = @_;

	return ($self->{in}, $self->{out}) if $self->{in};

	my ($in_r, $out_r, $out_w);
	pipe($out_r, $out_w) or die "pipe failed: $!";

	$self->lock_acquire;
	eval {
		my ($git, $ref) = @$self{qw(git ref)};
		local $/ = "\n";
		chomp($self->{tip} = $git->qx(qw(rev-parse --revs-only), $ref));
		die "fatal: rev-parse --revs-only $ref: \$?=$?" if $?;
		if ($self->{path_type} ne '2/38' && $self->{tip}) {
			my $t = $git->qx(qw(ls-tree -r -z --name-only), $ref);
			die "fatal: ls-tree -r -z --name-only $ref: \$?=$?" if $?;
			$self->{-tree} = { map { $_ => 1 } split(/\0/, $t) };
		}
		$in_r = $self->{in} = $git->popen(qw(fast-import
					--quiet --done --date-format=raw),
					undef, { 0 => $out_r });
		$out_w->autoflush(1);
		$self->{out} = $out_w;
		$self->{nchg} = 0;
	};
	if ($@) {
		$self->lock_release;
		die $@;
	}
	($in_r, $out_w);
}

sub wfail () { die "write to fast-import failed: $!" }

sub now_raw () { time . ' +0000' }

sub norm_body ($) {
	my ($mime) = @_;
	my $b = $mime->body_raw;
	$b =~ s/(\r?\n)+\z//s;
	$b
}

# only used for v1 (ssoma) inboxes
sub _check_path ($$$$) {
	my ($r, $w, $tip, $path) = @_;
	return if $tip eq '';
	print $w "ls $tip $path\n" or wfail;
	local $/ = "\n";
	defined(my $info = <$r>) or die "EOF from fast-import: $!";
	$info =~ /\Amissing / ? undef : $info;
}

sub _cat_blob ($$$) {
	my ($r, $w, $oid) = @_;
	print $w "cat-blob $oid\n" or wfail;
	local $/ = "\n";
	my $info = <$r>;
	defined $info or die "EOF from fast-import / cat-blob: $!";
	$info =~ /\A[a-f0-9]{40,} blob ([0-9]+)\n\z/ or return;
	my $left = $1;
	my $offset = 0;
	my $buf = '';
	my $n;
	while ($left > 0) {
		$n = read($r, $buf, $left, $offset);
		defined($n) or die "read cat-blob failed: $!";
		$n == 0 and die 'fast-export (cat-blob) died';
		$left -= $n;
		$offset += $n;
	}
	$n = read($r, my $lf, 1);
	defined($n) or die "read final byte of cat-blob failed: $!";
	die "bad read on final byte: <$lf>" if $lf ne "\n";

	# fixup some bugginess in old versions:
	$buf =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
	\$buf;
}

sub cat_blob {
	my ($self, $oid) = @_;
	my ($r, $w) = $self->gfi_start;
	_cat_blob($r, $w, $oid);
}

sub check_remove_v1 {
	my ($r, $w, $tip, $path, $mime) = @_;

	my $info = _check_path($r, $w, $tip, $path) or return ('MISSING',undef);
	$info =~ m!\A100644 blob ([a-f0-9]{40,})\t!s or die "not blob: $info";
	my $oid = $1;
	my $msg = _cat_blob($r, $w, $oid) or die "BUG: cat-blob $1 failed";
	my $cur = PublicInbox::Eml->new($msg);
	my $cur_s = $cur->header('Subject');
	$cur_s = '' unless defined $cur_s;
	my $cur_m = $mime->header('Subject');
	$cur_m = '' unless defined $cur_m;
	if ($cur_s ne $cur_m || norm_body($cur) ne norm_body($mime)) {
		return ('MISMATCH', $cur);
	}
	(undef, $cur);
}

sub checkpoint {
	my ($self) = @_;
	return unless $self->{in};
	print { $self->{out} } "checkpoint\n" or wfail;
	undef;
}

sub progress {
	my ($self, $msg) = @_;
	return unless $self->{in};
	print { $self->{out} } "progress $msg\n" or wfail;
	readline($self->{in}) eq "progress $msg\n" or die
		"progress $msg not received\n";
	undef;
}

sub _update_git_info ($$) {
	my ($self, $do_gc) = @_;
	# for compatibility with existing ssoma installations
	# we can probably remove this entirely by 2020
	my $git_dir = $self->{git}->{git_dir};
	my @cmd = ('git', "--git-dir=$git_dir");
	my $index = "$git_dir/ssoma.index";
	if (-e $index && !$ENV{FAST}) {
		my $env = { GIT_INDEX_FILE => $index };
		run_die([@cmd, qw(read-tree -m -v -i), $self->{ref}], $env);
	}
	eval { run_die([@cmd, 'update-server-info']) };
	my $ibx = $self->{ibx};
	if ($ibx && $ibx->version == 1 && -d "$ibx->{inboxdir}/public-inbox" &&
				eval { require PublicInbox::SearchIdx }) {
		eval {
			my $s = PublicInbox::SearchIdx->new($ibx);
			$s->index_sync({ ref => $self->{ref} });
		};
		warn "$ibx->{inboxdir} index failed: $@\n" if $@;
	}
	eval { run_die([@cmd, qw(gc --auto)]) } if $do_gc;
}

sub barrier {
	my ($self) = @_;

	# For safety, we ensure git checkpoint is complete before because
	# the data in git is still more important than what is in Xapian
	# in v2.  Performance may be gained by delaying the ->progress
	# call but we lose safety
	if ($self->{nchg}) {
		$self->checkpoint;
		$self->progress('checkpoint');
		_update_git_info($self, 0);
		$self->{nchg} = 0;
	}
}

# used for v2
sub get_mark {
	my ($self, $mark) = @_;
	die "not active\n" unless $self->{in};
	my ($r, $w) = $self->gfi_start;
	print $w "get-mark $mark\n" or wfail;
	defined(my $oid = <$r>) or die "get-mark failed, need git 2.6.0+\n";
	chomp($oid);
	$oid;
}

# returns undef on non-existent
# ('MISMATCH', PublicInbox::Eml) on mismatch
# (:MARK, PublicInbox::Eml) on success
#
# v2 callers should check with Xapian before calling this as
# it is not idempotent.
sub remove {
	my ($self, $mime, $msg) = @_; # mime = PublicInbox::Eml or Email::MIME

	my $path_type = $self->{path_type};
	my ($path, $err, $cur, $blob);

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	if ($path_type eq '2/38') {
		$path = mid2path(v1_mid0($mime));
		($err, $cur) = check_remove_v1($r, $w, $tip, $path, $mime);
		return ($err, $cur) if $err;
	} else {
		my $sref;
		if (ref($mime) eq 'SCALAR') { # optimization used by V2Writable
			$sref = $mime;
		} else { # XXX should not be necessary:
			my $str = $mime->as_string;
			$sref = \$str;
		}
		my $len = length($$sref);
		$blob = $self->{mark}++;
		print $w "blob\nmark :$blob\ndata $len\n",
			$$sref, "\n" or wfail;
	}

	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;
	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}
	my $ident = $self->{ident};
	my $now = now_raw();
	$msg //= 'rm';
	my $len = length($msg) + 1;
	print $w "commit $ref\nmark :$commit\n",
		"author $ident $now\n",
		"committer $ident $now\n",
		"data $len\n$msg\n\n",
		'from ', ($parent ? $parent : $tip), "\n" or wfail;
	if (defined $path) {
		print $w "D $path\n\n" or wfail;
	} else {
		clean_tree_v2($self, $w, 'd');
		print $w "M 100644 :$blob d\n\n" or wfail;
	}
	$self->{nchg}++;
	(($self->{tip} = ":$commit"), $cur);
}

sub git_timestamp ($) {
	my ($ts, $zone) = @{$_[0]};
	$ts = 0 if $ts < 0; # git uses unsigned times
	"$ts $zone";
}

sub extract_cmt_info ($;$) {
	my ($mime, $smsg) = @_;
	# $mime is PublicInbox::Eml, but remains Email::MIME-compatible
	$smsg //= bless {}, 'PublicInbox::Smsg';

	$smsg->populate($mime);

	my $sender = '';
	my $from = delete($smsg->{From}) // '';
	my ($email) = PublicInbox::Address::emails($from);
	my ($name) = PublicInbox::Address::names($from);
	if (!defined($name) || !defined($email)) {
		$sender = $mime->header('Sender') // '';
		$name //= (PublicInbox::Address::names($sender))[0];
		$email //= (PublicInbox::Address::emails($sender))[0];
	}
	if (defined $email) {
		# Email::Address::XS may leave quoted '<' in addresses,
		# which git-fast-import doesn't like
		$email =~ tr/<>//d;

		# quiet down wide character warnings with utf8::encode
		utf8::encode($email);
	} else {
		$email = '';
		warn "no email in From: $from or Sender: $sender\n";
	}

	# git gets confused with:
	#  "'A U Thor <u@example.com>' via foo" <foo@example.com>
	# ref:
	# <CAD0k6qSUYANxbjjbE4jTW4EeVwOYgBD=bXkSu=akiYC_CB7Ffw@mail.gmail.com>
	if (defined $name) {
		$name =~ tr/<>//d;
		utf8::encode($name);
	} else {
		$name = '';
		warn "no name in From: $from or Sender: $sender\n";
	}

	my $subject = delete($smsg->{Subject}) // '(no subject)';
	utf8::encode($subject);
	my $at = git_timestamp(delete $smsg->{-ds});
	my $ct = git_timestamp(delete $smsg->{-ts});
	("$name <$email>", $at, $ct, $subject);
}

# kill potentially confusing/misleading headers
our @UNWANTED_HEADERS = (qw(Bytes Lines Content-Length),
			qw(Status X-Status));
sub drop_unwanted_headers ($) {
	my ($eml) = @_;
	for (@UNWANTED_HEADERS, @PublicInbox::MDA::BAD_HEADERS) {
		$eml->header_set($_);
	}
}

# used by V2Writable, too
sub append_mid ($$) {
	my ($hdr, $mid0) = @_;
	# @cur is likely empty if we need to call this sub, but it could
	# have random unparseable crap which we'll preserve, too.
	my @cur = $hdr->header_raw('Message-ID');
	$hdr->header_set('Message-ID', @cur, "<$mid0>");
}

sub v1_mid0 ($) {
	my ($eml) = @_;
	my $mids = mids($eml);

	if (!scalar(@$mids)) { # spam often has no Message-ID
		my $mid0 = digest2mid(content_digest($eml), $eml);
		append_mid($eml, $mid0);
		return $mid0;
	}
	$mids->[0];
}
sub clean_tree_v2 ($$$) {
	my ($self, $w, $keep) = @_;
	my $tree = $self->{-tree} or return; #v2 only
	delete $tree->{$keep};
	foreach (keys %$tree) {
		print $w "D $_\n" or wfail;
	}
	%$tree = ($keep => 1);
}

# returns undef on duplicate
# returns the :MARK of the most recent commit
sub add {
	my ($self, $mime, $check_cb, $smsg) = @_;

	my ($author, $at, $ct, $subject) = extract_cmt_info($mime, $smsg);
	my $path_type = $self->{path_type};
	my $path;
	if ($path_type eq '2/38') {
		$path = mid2path(v1_mid0($mime));
	} else { # v2 layout, one file:
		$path = 'm';
	}

	my ($r, $w) = $self->gfi_start;
	my $tip = $self->{tip};
	if ($path_type eq '2/38') {
		_check_path($r, $w, $tip, $path) and return;
	}

	drop_unwanted_headers($mime);

	# spam check:
	if ($check_cb) {
		$mime = $check_cb->($mime, $self->{ibx}) or return;
	}

	my $blob = $self->{mark}++;
	my $raw_email = $mime->{-public_inbox_raw} // $mime->as_string;
	my $n = length($raw_email);
	$self->{bytes_added} += $n;
	print $w "blob\nmark :$blob\ndata ", $n, "\n" or wfail;
	print $w $raw_email, "\n" or wfail;

	# v2: we need this for Xapian
	if ($smsg) {
		$smsg->{blob} = $self->get_mark(":$blob");
		$smsg->set_bytes($raw_email, $n);
		if (my $oidx = delete $smsg->{-oidx}) { # used by LeiStore
			my $eidx_git = delete $smsg->{-eidx_git};

			# we need this sharedkv to dedupe blobs added in the
			# same fast-import transaction
			my $u = $self->{uniq_skv} //= do {
				require PublicInbox::SharedKV;
				my $x = PublicInbox::SharedKV->new;
				$x->dbh;
				$x;
			};
			return if !$u->set_maybe($smsg->oidbin, 1);
			return if (!$oidx->vivify_xvmd($smsg) &&
					$eidx_git->check($smsg->{blob}));
		}
	}
	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;

	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}

	print $w "commit $ref\nmark :$commit\n",
		"author $author $at\n",
		"committer $self->{ident} $ct\n" or wfail;
	print $w "data ", (length($subject) + 1), "\n",
		$subject, "\n\n" or wfail;
	if ($tip ne '') {
		print $w 'from ', ($parent ? $parent : $tip), "\n" or wfail;
	}
	clean_tree_v2($self, $w, $path);
	print $w "M 100644 :$blob $path\n\n" or wfail;
	$self->{nchg}++;
	$self->{tip} = ":$commit";
}

my @INIT_FILES = ('HEAD' => undef, # filled in at runtime
		'config' => <<EOC);
[core]
	repositoryFormatVersion = 0
	filemode = true
	bare = true
[repack]
	writeBitmaps = true
EOC

sub init_bare {
	my ($dir, $head) = @_; # or self
	$dir = $dir->{git}->{git_dir} if ref($dir);
	require File::Path;
	File::Path::mkpath([ map { "$dir/$_" } qw(objects/info refs/heads) ]);
	$INIT_FILES[1] //= 'ref: '.default_branch."\n";
	my @fn_contents = @INIT_FILES;
	$fn_contents[1] = "ref: refs/heads/$head\n" if defined $head;
	while (my ($fn, $contents) = splice(@fn_contents, 0, 2)) {
		my $f = $dir.'/'.$fn;
		next if -f $f;
		open my $fh, '>', $f or die "open $f: $!";
		print $fh $contents or die "print $f: $!";
		close $fh or die "close $f: $!";
	}
}

# true if locked and active
sub active { !!$_[0]->{out} }

sub done {
	my ($self) = @_;
	my $w = delete $self->{out} or return;
	eval {
		my $r = delete $self->{in} or die 'BUG: missing {in} when done';
		print $w "done\n" or wfail;
		close $r or die "fast-import failed: $?"; # ProcessPipe::CLOSE
	};
	my $wait_err = $@;
	my $nchg = delete $self->{nchg};
	if ($nchg && !$wait_err) {
		eval { _update_git_info($self, 1) };
		warn "E: $self->{git}->{git_dir} update info: $@\n" if $@;
	}
	$self->lock_release(!!$nchg);
	$self->{git}->cleanup;
	die $wait_err if $wait_err;
}

sub atfork_child {
	my ($self) = @_;
	foreach my $f (qw(in out)) {
		next unless defined($self->{$f});
		close $self->{$f} or die "failed to close import[$f]: $!\n";
	}
}

sub digest2mid ($$;$) {
	my ($dig, $hdr, $fallback_time) = @_;
	my $b64 = $dig->clone->b64digest;
	# Make our own URLs nicer:
	# See "Base 64 Encoding with URL and Filename Safe Alphabet" in RFC4648
	$b64 =~ tr!+/=!-_!d;

	# Add a date prefix to prevent a leading '-' in case that trips
	# up some tools (e.g. if a Message-ID were a expected as a
	# command-line arg)
	my $dt = msg_datestamp($hdr, $fallback_time);
	$dt = POSIX::strftime('%Y%m%d%H%M%S', gmtime($dt));
	"$dt.$b64" . '@z';
}

sub rewrite_commit ($$$$) {
	my ($self, $oids, $buf, $mime) = @_;
	my ($author, $at, $ct, $subject);
	if ($mime) {
		($author, $at, $ct, $subject) = extract_cmt_info($mime);
	} else {
		$author = '<>';
		$subject = 'purged '.join(' ', @$oids);
	}
	@$oids = ();
	$subject .= "\n";
	foreach my $i (0..$#$buf) {
		my $l = $buf->[$i];
		if ($l =~ /^author .* ([0-9]+ [\+-]?[0-9]+)$/) {
			$at //= $1;
			$buf->[$i] = "author $author $at\n";
		} elsif ($l =~ /^committer .* ([0-9]+ [\+-]?[0-9]+)$/) {
			$ct //= $1;
			$buf->[$i] = "committer $self->{ident} $ct\n";
		} elsif ($l =~ /^data ([0-9]+)/) {
			$buf->[$i++] = "data " . length($subject) . "\n";
			$buf->[$i] = $subject;
			last;
		}
	}
}

# returns the new commit OID if a replacement was done
# returns undef if nothing was done
sub replace_oids {
	my ($self, $mime, $replace_map) = @_; # oid => raw string
	my $tmp = "refs/heads/replace-".((keys %$replace_map)[0]);
	my $old = $self->{'ref'};
	my $git = $self->{git};
	my @export = (qw(fast-export --no-data --use-done-feature), $old);
	my $rd = $git->popen(@export);
	my ($r, $w) = $self->gfi_start;
	my @buf;
	my $nreplace = 0;
	my @oids;
	my ($done, $mark);
	my $tree = $self->{-tree};
	while (<$rd>) {
		if (/^reset (?:.+)/) {
			push @buf, "reset $tmp\n";
		} elsif (/^commit (?:.+)/) {
			if (@buf) {
				print $w @buf or wfail;
				@buf = ();
			}
			push @buf, "commit $tmp\n";
		} elsif (/^data ([0-9]+)/) {
			# only commit message, so $len is small:
			my $len = $1; # + 1 for trailing "\n"
			push @buf, $_;
			my $n = read($rd, my $buf, $len) or die "read: $!";
			$len == $n or die "short read ($n < $len)";
			push @buf, $buf;
		} elsif (/^M 100644 ([a-f0-9]+) (\w+)/) {
			my ($oid, $path) = ($1, $2);
			$tree->{$path} = 1;
			my $sref = $replace_map->{$oid};
			if (defined $sref) {
				push @oids, $oid;
				my $n = length($$sref);
				push @buf, "M 100644 inline $path\ndata $n\n";
				push @buf, $$sref; # hope CoW works...
				push @buf, "\n";
			} else {
				push @buf, $_;
			}
		} elsif (/^D (\w+)/) {
			my $path = $1;
			push @buf, $_ if $tree->{$path};
		} elsif ($_ eq "\n") {
			if (@oids) {
				if (!$mime) {
					my $out = join('', @buf);
					$out =~ s/^/# /sgm;
					warn "purge rewriting\n", $out, "\n";
				}
				rewrite_commit($self, \@oids, \@buf, $mime);
				$nreplace++;
			}
			print $w @buf, "\n" or wfail;
			@buf = ();
		} elsif ($_ eq "done\n") {
			$done = 1;
		} elsif (/^mark :([0-9]+)$/) {
			push @buf, $_;
			$mark = $1;
		} else {
			push @buf, $_;
		}
	}
	close $rd or die "close fast-export failed: $?";
	if (@buf) {
		print $w @buf or wfail;
	}
	die 'done\n not seen from fast-export' unless $done;
	chomp(my $cmt = $self->get_mark(":$mark")) if $nreplace;
	$self->{nchg} = 0; # prevent _update_git_info until update-ref:
	$self->done;
	my @git = ('git', "--git-dir=$git->{git_dir}");

	run_die([@git, qw(update-ref), $old, $tmp]) if $nreplace;

	run_die([@git, qw(update-ref -d), $tmp]);

	return if $nreplace == 0;

	run_die([@git, qw(-c gc.reflogExpire=now gc --prune=all --quiet)]);

	# check that old OIDs are gone
	my $err = 0;
	foreach my $oid (keys %$replace_map) {
		my @info = $git->check($oid);
		if (@info) {
			warn "$oid not replaced\n";
			$err++;
		}
	}
	_update_git_info($self, 0);
	die "Failed to replace $err object(s)\n" if $err;
	$cmt;
}

1;
__END__
=pod

=head1 NAME

PublicInbox::Import - message importer for public-inbox v1 inboxes

=head1 VERSION

version 1.0

=head1 SYNOPSIS

	use PublicInbox::Eml;
	# PublicInbox::Eml exists as of public-inbox 1.5.0,
	# Email::MIME was used in older versions

	use PublicInbox::Git;
	use PublicInbox::Import;

	chomp(my $git_dir = `git rev-parse --git-dir`);
	$git_dir or die "GIT_DIR= must be specified\n";
	my $git = PublicInbox::Git->new($git_dir);
	my @committer = ('inbox', 'inbox@example.org');
	my $im = PublicInbox::Import->new($git, @committer);

	# to add a message:
	my $message = "From: <u\@example.org>\n".
		"Subject: test message \n" .
		"Date: Thu, 01 Jan 1970 00:00:00 +0000\n" .
		"Message-ID: <m\@example.org>\n".
		"\ntest message";
	my $parsed = PublicInbox::Eml->new($message);
	my $ret = $im->add($parsed);
	if (!defined $ret) {
		warn "duplicate: ", $parsed->header_raw('Message-ID'), "\n";
	} else {
		print "imported at mark $ret\n";
	}
	$im->done;

	# to remove a message
	my $junk = PublicInbox::Eml->new($message);
	my ($mark, $orig) = $im->remove($junk);
	if ($mark eq 'MISSING') {
		print "not found\n";
	} elsif ($mark eq 'MISMATCH') {
		print "Message exists but does not match\n\n",
			$orig->as_string, "\n",;
	} else {
		print "removed at mark $mark\n\n",
			$orig->as_string, "\n";
	}
	$im->done;

=head1 DESCRIPTION

An importer and remover for public-inboxes which takes C<PublicInbox::Eml>
or L<Email::MIME> messages as input and stores them in a git repository as
documented in L<https://public-inbox.org/public-inbox-v1-format.txt>,
except it does not allow duplicate Message-IDs.

It requires L<git(1)> and L<git-fast-import(1)> to be installed.

=head1 METHODS

=cut

=head2 new

	my $im = PublicInbox::Import->new($git, @committer);

Initialize a new PublicInbox::Import object.

=head2 add

	my $parsed = PublicInbox::Eml->new($message);
	$im->add($parsed);

Adds a message to to the git repository.  This will acquire
C<$GIT_DIR/ssoma.lock> and start L<git-fast-import(1)> if necessary.

Messages added will not be visible to other processes until L</done>
is called, but L</remove> may be called on them.

=head2 remove

	my $junk = PublicInbox::Eml->new($message);
	my ($code, $orig) = $im->remove($junk);

Removes a message from the repository.  On success, it returns
a ':'-prefixed numeric code representing the git-fast-import
mark and the original messages as a PublicInbox::Eml
(or Email::MIME) object.
If the message could not be found, the code is "MISSING"
and the original message is undef.  If there is a mismatch where
the "Message-ID" is matched but the subject and body do not match,
the returned code is "MISMATCH" and the conflicting message
is returned as orig.

=head2 done

Finalizes the L<git-fast-import(1)> and unlocks the repository.
Calling this is required to finalize changes to a repository.

=head1 SEE ALSO

L<Email::MIME>

=head1 CONTACT

All feedback welcome via plain-text mail to L<mailto:meta@public-inbox.org>

The mail archives are hosted at L<https://public-inbox.org/meta/>

=head1 COPYRIGHT

Copyright (C) 2016-2020 all contributors L<mailto:meta@public-inbox.org>

License: AGPL-3.0+ L<http://www.gnu.org/licenses/agpl-3.0.txt>

=cut
