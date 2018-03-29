# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# git fast-import-based ssoma-mda MDA replacement
# This is only ever run by public-inbox-mda and public-inbox-learn,
# not the WWW or NNTP code which only requires read-only access.
package PublicInbox::Import;
use strict;
use warnings;
use base qw(PublicInbox::Lock);
use PublicInbox::Spawn qw(spawn);
use PublicInbox::MID qw(mids mid_mime mid2path);
use PublicInbox::Address;
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);
use PublicInbox::ContentId qw(content_digest);
use PublicInbox::MDA;

sub new {
	my ($class, $git, $name, $email, $ibx) = @_;
	my $ref = 'refs/heads/master';
	if ($ibx) {
		$ref = $ibx->{ref_head} || 'refs/heads/master';
		$name ||= $ibx->{name};
		$email ||= $ibx->{-primary_address};
	}
	bless {
		git => $git,
		ident => "$name <$email>",
		mark => 1,
		ref => $ref,
		inbox => $ibx,
		path_type => '2/38', # or 'v2'
		lock_path => "$git->{git_dir}/ssoma.lock", # v2 changes this
		bytes_added => 0,
	}, $class
}

# idempotent start function
sub gfi_start {
	my ($self) = @_;

	return ($self->{in}, $self->{out}) if $self->{pid};

	my ($in_r, $in_w, $out_r, $out_w);
	pipe($in_r, $in_w) or die "pipe failed: $!";
	pipe($out_r, $out_w) or die "pipe failed: $!";
	my $git = $self->{git};

	$self->lock_acquire;

	local $/ = "\n";
	chomp($self->{tip} = $git->qx(qw(rev-parse --revs-only), $self->{ref}));

	my $git_dir = $git->{git_dir};
	my @cmd = ('git', "--git-dir=$git_dir", qw(fast-import
			--quiet --done --date-format=raw));
	my $rdr = { 0 => fileno($out_r), 1 => fileno($in_w) };
	my $pid = spawn(\@cmd, undef, $rdr);
	die "spawn fast-import failed: $!" unless defined $pid;
	$out_w->autoflush(1);
	$self->{in} = $in_r;
	$self->{out} = $out_w;
	$self->{pid} = $pid;
	$self->{nchg} = 0;
	binmode $out_w, ':raw' or die "binmode :raw failed: $!";
	binmode $in_r, ':raw' or die "binmode :raw failed: $!";
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

sub check_remove_v1 {
	my ($r, $w, $tip, $path, $mime) = @_;

	my $info = _check_path($r, $w, $tip, $path) or return ('MISSING',undef);
	$info =~ m!\A100644 blob ([a-f0-9]{40})\t!s or die "not blob: $info";
	my $blob = $1;

	print $w "cat-blob $blob\n" or wfail;
	local $/ = "\n";
	$info = <$r>;
	defined $info or die "EOF from fast-import / cat-blob: $!";
	$info =~ /\A[a-f0-9]{40} blob (\d+)\n\z/ or
				die "unexpected cat-blob response: $info";
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
	my $cur = PublicInbox::MIME->new(\$buf);
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
	return unless $self->{pid};
	print { $self->{out} } "checkpoint\n" or wfail;
	undef;
}

sub progress {
	my ($self, $msg) = @_;
	return unless $self->{pid};
	print { $self->{out} } "progress $msg\n" or wfail;
	$self->{in}->getline eq "progress $msg\n" or die
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
	run_die([@cmd, 'update-server-info'], undef);
	($self->{path_type} eq '2/38') and eval {
		require PublicInbox::SearchIdx;
		my $inbox = $self->{inbox} || $git_dir;
		my $s = PublicInbox::SearchIdx->new($inbox);
		$s->index_sync({ ref => $self->{ref} });
	};
	eval { run_die([@cmd, qw(gc --auto)], undef) } if $do_gc;
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
	die "not active\n" unless $self->{pid};
	my ($r, $w) = $self->gfi_start;
	print $w "get-mark $mark\n" or wfail;
	defined(my $oid = <$r>) or die "get-mark failed, need git 2.6.0+\n";
	$oid;
}

# returns undef on non-existent
# ('MISMATCH', Email::MIME) on mismatch
# (:MARK, Email::MIME) on success
#
# v2 callers should check with Xapian before calling this as
# it is not idempotent.
sub remove {
	my ($self, $mime, $msg) = @_; # mime = Email::MIME

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
	$msg ||= 'rm';
	my $len = length($msg) + 1;
	print $w "commit $ref\nmark :$commit\n",
		"author $ident $now\n",
		"committer $ident $now\n",
		"data $len\n$msg\n\n",
		'from ', ($parent ? $parent : $tip), "\n" or wfail;
	if (defined $path) {
		print $w "D $path\n\n" or wfail;
	} else {
		print $w "M 100644 :$blob _/D\n\n" or wfail;
	}
	$self->{nchg}++;
	(($self->{tip} = ":$commit"), $cur);
}

sub git_timestamp {
	my ($ts, $zone) = @_;
	$ts = 0 if $ts < 0; # git uses unsigned times
	"$ts $zone";
}

sub extract_author_info ($) {
	my ($mime) = @_;

	my $sender = '';
	my $from = $mime->header('From');
	my ($email) = PublicInbox::Address::emails($from);
	my ($name) = PublicInbox::Address::names($from);
	if (!defined($name) || !defined($email)) {
		$sender = $mime->header('Sender');
		if (!defined($name)) {
			($name) = PublicInbox::Address::names($sender);
		}
		if (!defined($email)) {
			($email) = PublicInbox::Address::emails($sender);
		}
	}
	if (defined $email) {
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
	($name, $email);
}

# kill potentially confusing/misleading headers
sub drop_unwanted_headers ($) {
	my ($mime) = @_;

	$mime->header_set($_) for qw(bytes lines content-length status);
	$mime->header_set($_) for @PublicInbox::MDA::BAD_HEADERS;
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
	my ($mime) = @_;
	my $hdr = $mime->header_obj;
	my $mids = mids($hdr);

	if (!scalar(@$mids)) { # spam often has no Message-Id
		my $mid0 = digest2mid(content_digest($mime));
		append_mid($hdr, $mid0);
		return $mid0;
	}
	$mids->[0];
}

# returns undef on duplicate
# returns the :MARK of the most recent commit
sub add {
	my ($self, $mime, $check_cb) = @_; # mime = Email::MIME

	my ($name, $email) = extract_author_info($mime);
	my $hdr = $mime->header_obj;
	my @at = msg_datestamp($hdr);
	my @ct = msg_timestamp($hdr);
	my $author_time_raw = git_timestamp(@at);
	my $commit_time_raw = git_timestamp(@ct);
	my $subject = $mime->header('Subject');
	$subject = '(no subject)' unless defined $subject;
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
		$mime = $check_cb->($mime) or return;
	}

	my $blob = $self->{mark}++;
	my $str = $mime->as_string;
	my $n = length($str);
	$self->{bytes_added} += $n;
	print $w "blob\nmark :$blob\ndata ", $n, "\n" or wfail;
	print $w $str, "\n" or wfail;

	# v2: we need this for Xapian
	if ($self->{want_object_info}) {
		chomp(my $oid = $self->get_mark(":$blob"));
		$self->{last_object} = [ $oid, $n, \$str ];
	}
	my $ref = $self->{ref};
	my $commit = $self->{mark}++;
	my $parent = $tip =~ /\A:/ ? $tip : undef;

	unless ($parent) {
		print $w "reset $ref\n" or wfail;
	}

	utf8::encode($subject);
	print $w "commit $ref\nmark :$commit\n",
		"author $name <$email> $author_time_raw\n",
		"committer $self->{ident} $commit_time_raw\n" or wfail;
	print $w "data ", (length($subject) + 1), "\n",
		$subject, "\n\n" or wfail;
	if ($tip ne '') {
		print $w 'from ', ($parent ? $parent : $tip), "\n" or wfail;
	}
	print $w "M 100644 :$blob $path\n\n" or wfail;
	$self->{nchg}++;
	$self->{tip} = ":$commit";
}

sub run_die ($;$$) {
	my ($cmd, $env, $rdr) = @_;
	my $pid = spawn($cmd, $env, $rdr);
	defined $pid or die "spawning ".join(' ', @$cmd)." failed: $!";
	waitpid($pid, 0) == $pid or die join(' ', @$cmd) .' did not finish';
	$? == 0 or die join(' ', @$cmd) . " failed: $?\n";
}

sub done {
	my ($self) = @_;
	my $w = delete $self->{out} or return;
	my $r = delete $self->{in} or die 'BUG: missing {in} when done';
	print $w "done\n" or wfail;
	my $pid = delete $self->{pid} or die 'BUG: missing {pid} when done';
	waitpid($pid, 0) == $pid or die 'fast-import did not finish';
	$? == 0 or die "fast-import failed: $?";

	_update_git_info($self, 1) if delete $self->{nchg};

	$self->lock_release;
}

sub atfork_child {
	my ($self) = @_;
	foreach my $f (qw(in out)) {
		close $self->{$f} or die "failed to close import[$f]: $!\n";
	}
}

sub digest2mid ($) {
	my ($dig) = @_;
	my $b64 = $dig->clone->b64digest;
	# Make our own URLs nicer:
	# See "Base 64 Encoding with URL and Filename Safe Alphabet" in RFC4648
	$b64 =~ tr!+/=!-_!d;

	# We can make this more meaningful with a date prefix or other things,
	# but this is only needed for crap that fails to generate a Message-ID
	# or reuses one.  In other words, it's usually spammers who hit this
	# so they don't deserve nice Message-IDs :P
	$b64 . '@localhost';
}

sub clean_purge_buffer {
	my ($oid, $buf) = @_;
	my $cmt_msg = "purged $oid\n";

	foreach my $i (0..$#$buf) {
		my $l = $buf->[$i];
		if ($l =~ /^author .* (\d+ [\+-]?\d+)$/) {
			$buf->[$i] = "author <> $1\n";
		} elsif ($l =~ /^data (\d+)/) {
			$buf->[$i++] = "data " . length($cmt_msg) . "\n";
			$buf->[$i] = $cmt_msg;
			last;
		}
	}
}

sub purge_oids {
	my ($self, $purge) = @_;
	my $tmp = "refs/heads/purge-".((keys %$purge)[0]);
	my $old = $self->{'ref'};
	my $git = $self->{git};
	my @export = (qw(fast-export --no-data --use-done-feature), $old);
	my ($rd, $pid) = $git->popen(@export);
	my ($r, $w) = $self->gfi_start;
	my @buf;
	my $npurge = 0;
	while (<$rd>) {
		if (/^reset (?:.+)/) {
			push @buf, "reset $tmp\n";
		} elsif (/^commit (?:.+)/) {
			if (@buf) {
				$w->print(@buf) or wfail;
				@buf = ();
			}
			push @buf, "commit $tmp\n";
		} elsif (/^data (\d+)/) {
			# only commit message, so $len is small:
			my $len = $1; # + 1 for trailing "\n"
			push @buf, $_;
			my $n = read($rd, my $buf, $len) or die "read: $!";
			$len == $n or die "short read ($n < $len)";
			push @buf, $buf;
		} elsif (/^M 100644 ([a-f0-9]+) /) {
			my $oid = $1;
			if ($purge->{$oid}) {
				my $lf = <$rd>;
				if ($lf eq "\n") {
					my $out = join('', @buf);
					$out =~ s/^/# /sgm;
					warn "purge rewriting\n", $out, "\n";
					clean_purge_buffer($oid, \@buf);
					$out = join('', @buf);
					$w->print(@buf, "\n") or wfail;
					@buf = ();
					$npurge++;
				} else {
					die "expected LF: $lf\n";
				}
			} else {
				push @buf, $_;
			}
		} else {
			push @buf, $_;
		}
	}
	if (@buf) {
		$w->print(@buf) or wfail;
	}
	$w = $r = undef;
	$self->done;
	my @git = ('git', "--git-dir=$git->{git_dir}");

	run_die([@git, qw(update-ref), $old, $tmp]) if $npurge;

	run_die([@git, qw(update-ref -d), $tmp]);

	return if $npurge == 0;

	run_die([@git, qw(-c gc.reflogExpire=now gc --prune=all)]);
	my $err = 0;
	foreach my $oid (keys %$purge) {
		my @info = $git->check($oid);
		if (@info) {
			warn "$oid not purged\n";
			$err++;
		}
	}
	die "Failed to purge $err object(s)\n" if $err;
}

1;
__END__
=pod

=head1 NAME

PublicInbox::Import - message importer for public-inbox

=head1 VERSION

version 1.0

=head1 SYNOPSYS

	use Email::MIME;
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
	my $parsed = Email::MIME->new($message);
	my $ret = $im->add($parsed);
	if (!defined $ret) {
		warn "duplicate: ",
			$parsed->header_obj->header_raw('Message-ID'), "\n";
	} else {
		print "imported at mark $ret\n";
	}
	$im->done;

	# to remove a message
	my $junk = Email::MIME->new($message);
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

An importer and remover for public-inboxes which takes L<Email::MIME>
messages as input and stores them in a ssoma repository as
documented in L<https://ssoma.public-inbox.org/ssoma_repository.txt>,
except it does not allow duplicate Message-IDs.

It requires L<git(1)> and L<git-fast-import(1)> to be installed.

=head1 METHODS

=cut

=head2 new

	my $im = PublicInbox::Import->new($git, @committer);

Initialize a new PublicInbox::Import object.

=head2 add

	my $parsed = Email::MIME->new($message);
	$im->add($parsed);

Adds a message to to the git repository.  This will acquire
C<$GIT_DIR/ssoma.lock> and start L<git-fast-import(1)> if necessary.

Messages added will not be visible to other processes until L</done>
is called, but L</remove> may be called on them.

=head2 remove

	my $junk = Email::MIME->new($message);
	my ($code, $orig) = $im->remove($junk);

Removes a message from the repository.  On success, it returns
a ':'-prefixed numeric code representing the git-fast-import
mark and the original messages as an Email::MIME object.
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

Copyright (C) 2016 all contributors L<mailto:meta@public-inbox.org>

License: AGPL-3.0+ L<http://www.gnu.org/licenses/agpl-3.0.txt>

=cut
