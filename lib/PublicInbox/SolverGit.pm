# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "Solve" blobs which don't exist in git code repositories by
# searching inboxes for post-image blobs.

# this emits a lot of debugging/tracing information which may be
# publicly viewed over HTTP(S).  Be careful not to expose
# local filesystem layouts in the process.
package PublicInbox::SolverGit;
use strict;
use v5.10.1;
use File::Temp 0.19 (); # 0.19 for ->newdir
use Fcntl qw(SEEK_SET);
use PublicInbox::Git qw(git_unquote git_quote);
use PublicInbox::MsgIter qw(msg_part_text);
use PublicInbox::Qspawn;
use PublicInbox::Tmpfile;
use PublicInbox::GitAsyncCat;
use PublicInbox::Eml;
use URI::Escape qw(uri_escape_utf8);

# POSIX requires _POSIX_ARG_MAX >= 4096, and xargs is required to
# subtract 2048 bytes.  We also don't factor in environment variable
# headroom into this.
use POSIX qw(sysconf _SC_ARG_MAX);
my $ARG_SIZE_MAX = (sysconf(_SC_ARG_MAX) || 4096) - 2048;
my $OID_MIN = 7;

# By default, "git format-patch" generates filenames with a four-digit
# prefix, so that means 9999 patch series are OK, right? :>
# Maybe we can make this configurable, main concern is disk space overhead
# for uncompressed patch fragments.  Aside from space, public-inbox-httpd
# is otherwise unaffected by having many patches, here, as it can share
# work fairly.  Other PSGI servers may have trouble, though.
my $MAX_PATCH = 9999;

my $LF = qr!\r?\n!;
my $ANY = qr![^\r\n]+!;
my $MODE = '100644|120000|100755';
my $FN = qr!(?:("?[^/\n]+/[^\r\n]+)|/dev/null)!;
my %BAD_COMPONENT = ('' => 1, '.' => 1, '..' => 1);

# di = diff info / a hashref with information about a diff ($di):
# {
#	oid_a => abbreviated pre-image oid,
#	oid_b => abbreviated post-image oid,
#	tmp => anonymous file handle with the diff,
#	hdr_lines => string of various header lines for mode information
#	mode_a => original mode of oid_a (string, not integer),
#	ibx => PublicInbox::Inbox object containing the diff
#	smsg => PublicInbox::Smsg object containing diff
#	path_a => pre-image path
#	path_b => post-image path
#	n => numeric path of the patch (relative to worktree)
# }

sub dbg ($$) {
	print { $_[0]->{out} } $_[1], "\n" or ERR($_[0], "print(dbg): $!");
}

sub done ($$) {
	my ($self, $res) = @_;
	my $ucb = delete($self->{user_cb}) or return;
	$ucb->($res, $self->{uarg});
}

sub ERR ($$) {
	my ($self, $err) = @_;
	print { $self->{out} } $err, "\n";
	eval { done($self, $err) };
	die $err;
}

# look for existing objects already in git repos, returns arrayref
# if found, number of remaining git coderepos to try if not.
sub solve_existing ($$) {
	my ($self, $want) = @_;
	my $try = $want->{try_gits} //= [ @{$self->{gits}} ]; # array copy
	my $git = shift @$try or die 'BUG {try_gits} empty';
	my $oid_b = $want->{oid_b};
	my ($oid_full, $type, $size) = $git->check($oid_b);

	# other than {oid_b, try_gits, try_ibxs}
	my $have_hints = scalar keys %$want > 3;
	if (defined($type) && (!$have_hints || $type eq 'blob')) {
		delete $want->{try_gits};
		return [ $git, $oid_full, $type, int($size) ]; # done, success
	}

	# TODO: deal with 40-char "abbreviations" with future SHA-256 git
	return scalar(@$try) if length($oid_b) >= 40;

	# parse stderr of "git cat-file --batch-check"
	my $err = $git->last_check_err;
	my (@oids) = ($err =~ /\b([a-f0-9]{40,})\s+blob\b/g);
	return scalar(@$try) unless scalar(@oids);

	# TODO: do something with the ambiguous array?
	# push @ambiguous, [ $git, @oids ];

	dbg($self, "`$oid_b' ambiguous in " .
			join("\n\t", $git->pub_urls($self->{psgi_env}))
			. "\n" .
			join('', map { "$_ blob\n" } @oids));
	scalar(@$try);
}

sub extract_diff ($$) {
	my ($p, $arg) = @_;
	my ($self, $want, $smsg) = @$arg;
	my ($part) = @$p; # ignore $depth and @idx;
	my $ct = $part->content_type || 'text/plain';
	my $post = $want->{oid_b};
	my $pre = $want->{oid_a};
	if (!defined($pre) || $pre !~ /\A[a-f0-9]+\z/) {
		$pre = '[a-f0-9]{7}'; # for RE below
	}

	# Email::MIME::Encodings forces QP to be CRLF upon decoding,
	# change it back to LF:
	my $cte = $part->header('Content-Transfer-Encoding') || '';
	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;
	delete $part->{bdy};
	if ($cte =~ /\bquoted-printable\b/i && $part->crlf eq "\n") {
		$s =~ s/\r\n/\n/sg;
	}
	$s =~ m!( # $1 start header lines we save for debugging:

		# everything before ^index is optional, but we don't
		# want to match ^(old|copy|rename|deleted|...) unless
		# we match /^diff --git/ first:
		(?: # begin optional stuff:

		# try to get the pre-and-post filenames as $2 and $3
		(?:^diff\x20--git\x20$FN\x20$FN$LF)

		(?:^(?: # pass all this to git-apply:
			# old mode $4
			(?:old\x20mode\x20($MODE))
			|
			# new mode (possibly new file) ($5)
			(?:new\x20(?:file\x20)?mode\x20($MODE))
			|
			(?:(?:copy|rename|deleted|
				dissimilarity|similarity)$ANY)
		)$LF)*

		)? # end of optional stuff, everything below is required

		# match the pre and post-image OIDs as $6 $7
		^index\x20(${pre}[a-f0-9]*)\.\.(${post}[a-f0-9]*)
			# mode if unchanged $8
			(?:\x20(100644|120000|100755))?$LF
	) # end of header lines ($1)
	( # $9 is the patch body
		# "--- a/foo.c" sets pre-filename ($10) in case
		# $2 is missing
		(?:^---\x20$FN$LF)

		# "+++ b/foo.c" sets post-filename ($11) in case
		# $3 is missing
		(?:^\+{3}\x20$FN$LF)

		# the meat of the diff, including "^\\No newline ..."
		# We also allow for totally blank lines w/o leading spaces,
		# because git-apply(1) handles that case, too
		(?:^(?:[\@\+\x20\-\\][^\n]*|)$LF)+
	)!smx or return;
	undef $s; # free memory

	my $di = {
		hdr_lines => $1,
		oid_a => $6,
		oid_b => $7,
		mode_a => $5 // $8 // $4, # new (file) // unchanged // old
	};
	my $path_a = $2 // $10;
	my $path_b = $3 // $11;
	my $patch = $9;

	# don't care for leading 'a/' and 'b/'
	my (undef, @a) = split(m{/}, git_unquote($path_a)) if defined($path_a);
	my (undef, @b) = split(m{/}, git_unquote($path_b));

	# get rid of path-traversal attempts and junk patches:
	# it's junk at best, an attack attempt at worse:
	foreach (@a, @b) { return if $BAD_COMPONENT{$_} }

	$di->{path_a} = join('/', @a) if @a;
	$di->{path_b} = join('/', @b);

	my $path = ++$self->{tot};
	$di->{n} = $path;
	open(my $tmp, '>:utf8', $self->{tmp}->dirname . "/$path") or
		die "open(tmp): $!";
	print $tmp $di->{hdr_lines}, $patch or die "print(tmp): $!";
	close $tmp or die "close(tmp): $!";

	# for debugging/diagnostics:
	$di->{ibx} = $want->{cur_ibx};
	$di->{smsg} = $smsg;

	push @{$self->{tmp_diffs}}, $di;
}

sub path_searchable ($) { defined($_[0]) && $_[0] =~ m!\A[\w/\. \-]+\z! }

# ".." appears in path names, which confuses Xapian into treating
# it as a range query.  So we split on ".." since Xapian breaks
# on punctuation anyways:
sub filename_query ($) {
	join('', map { qq( dfn:"$_") } split(/\.\./, $_[0]));
}

sub find_smsgs ($$$) {
	my ($self, $ibx, $want) = @_;
	my $srch = $ibx->isrch or return;

	my $post = $want->{oid_b} or die 'BUG: no {oid_b}';
	$post =~ /\A[a-f0-9]+\z/ or die "BUG: oid_b not hex: $post";

	my $q = "dfpost:$post";
	my $pre = $want->{oid_a};
	if (defined $pre && $pre =~ /\A[a-f0-9]+\z/) {
		$q .= " dfpre:$pre";
	}

	my $path_b = $want->{path_b};
	if (path_searchable($path_b)) {
		$q .= filename_query($path_b);

		my $path_a = $want->{path_a};
		if (path_searchable($path_a) && $path_a ne $path_b) {
			$q .= filename_query($path_a);
		}
	}
	my $mset = $srch->mset($q, { relevance => 1 });
	$mset->size ? $srch->mset_to_smsg($ibx, $mset) : undef;
}

sub update_index_result ($$) {
	my ($bref, $self) = @_;
	my ($qsp, $msg) = delete @$self{qw(-qsp -msg)};
	if (my $err = $qsp->{err}) {
		ERR($self, "git update-index error: $err");
	}
	dbg($self, $msg);
	next_step($self); # onto do_git_apply
}

sub prepare_index ($) {
	my ($self) = @_;
	my $patches = $self->{patches};
	$self->{nr} = 0;

	my $di = $patches->[0] or die 'no patches';
	my $oid_a = $di->{oid_a} or die '{oid_a} unset';
	my $existing = $self->{found}->{$oid_a};

	# no index creation for added files
	$oid_a =~ /\A0+\z/ and return next_step($self);

	die "BUG: $oid_a not found" unless $existing;

	my $oid_full = $existing->[1];
	my $path_a = $di->{path_a} or die "BUG: path_a missing for $oid_full";
	my $mode_a = $di->{mode_a} // '100644';

	my $in = tmpfile("update-index.$oid_full") or die "tmpfile: $!";
	print $in "$mode_a $oid_full\t$path_a\0" or die "print: $!";
	$in->flush or die "flush: $!";
	sysseek($in, 0, SEEK_SET) or die "seek: $!";

	dbg($self, 'preparing index');
	my $rdr = { 0 => $in };
	my $cmd = [ qw(git update-index -z --index-info) ];
	my $qsp = PublicInbox::Qspawn->new($cmd, $self->{git_env}, $rdr);
	$path_a = git_quote($path_a);
	$self->{-qsp} = $qsp;
	$self->{-msg} = "index prepared:\n$mode_a $oid_full\t$path_a";
	$qsp->psgi_qx($self->{psgi_env}, undef, \&update_index_result, $self);
}

# pure Perl "git init"
sub do_git_init ($) {
	my ($self) = @_;
	my $dir = $self->{tmp}->dirname;
	my $git_dir = "$dir/git";

	foreach ('', qw(objects refs objects/info refs/heads)) {
		mkdir("$git_dir/$_") or die "mkdir $_: $!";
	}
	open my $fh, '>', "$git_dir/config" or die "open git/config: $!";
	my $first = $self->{gits}->[0];
	my $fmt = $first->object_format;
	my $v = defined($$fmt) ? 1 : 0;
	print $fh <<EOF or die "print git/config $!";
[core]
	repositoryFormatVersion = $v
	filemode = true
	bare = false
	logAllRefUpdates = false
EOF
	print $fh <<EOM if defined($$fmt);
[extensions]
	objectformat = $$fmt
EOM
	close $fh or die "close git/config: $!";

	open $fh, '>', "$git_dir/HEAD" or die "open git/HEAD: $!";
	print $fh "ref: refs/heads/master\n" or die "print git/HEAD: $!";
	close $fh or die "close git/HEAD: $!";

	my $f = 'objects/info/alternates';
	open $fh, '>', "$git_dir/$f" or die "open: $f: $!";
	foreach my $git (@{$self->{gits}}) {
		print $fh $git->git_path('objects'),"\n" or die "print $f: $!";
	}
	close $fh or die "close: $f: $!";
	my $tmp_git = $self->{tmp_git} = PublicInbox::Git->new($git_dir);
	$tmp_git->{-tmp} = $self->{tmp};
	$self->{git_env} = {
		GIT_DIR => $git_dir,
		GIT_INDEX_FILE => "$git_dir/index",
		GIT_TEST_FSYNC => 0, # undocumented git env
	};
	prepare_index($self);
}

sub do_finish ($) {
	my ($self) = @_;
	my ($found, $oid_want) = @$self{qw(found oid_want)};
	if (my $exists = $found->{$oid_want}) {
		return done($self, $exists);
	}

	# let git disambiguate if oid_want was too short,
	# but long enough to be unambiguous:
	my $tmp_git = $self->{tmp_git};
	if (my @res = $tmp_git->check($oid_want)) {
		return done($self, $found->{$res[0]});
	}
	if (my $err = $tmp_git->last_check_err) {
		dbg($self, $err);
	}
	done($self, undef);
}

sub event_step ($) {
	my ($self) = @_;
	eval {
		# step 1: resolve blobs to patches in the todo queue
		if (my $want = pop @{$self->{todo}}) {
			# this populates {patches} and {todo}
			resolve_patch($self, $want);

		# step 2: then we instantiate a working tree once
		# the todo queue is finally empty:
		} elsif (!defined($self->{tmp_git})) {
			do_git_init($self);

		# step 3: apply each patch in the stack
		} elsif (scalar @{$self->{patches}}) {
			do_git_apply($self);

		# step 4: execute the user-supplied callback with
		# our result: (which may be undef)
		# Other steps may call user_cb to terminate prematurely
		# on error
		} elsif (exists $self->{user_cb}) {
			do_finish($self);
		} else {
			die 'about to call user_cb twice'; # Oops :x
		}
	}; # eval
	my $err = $@;
	if ($err) {
		$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
		dbg($self, "E: $err");
		eval { done($self, $err) };
	}
}

sub next_step ($) {
	my ($self) = @_;
	# if outside of public-inbox-httpd, caller is expected to be
	# looping event_step, anyways
	my $async = $self->{psgi_env}->{'pi-httpd.async'} or return;
	# PublicInbox::HTTPD::Async->new
	$async->(undef, undef, $self);
}

sub mark_found ($$$) {
	my ($self, $oid, $found_info) = @_;
	my $found = $self->{found};
	$found->{$oid} = $found_info;
	my $oid_cur = $found_info->[1];
	while ($oid_cur ne $oid && length($oid_cur) > $OID_MIN) {
		$found->{$oid_cur} = $found_info;
		chop($oid_cur);
	}
}

sub parse_ls_files ($$) {
	my ($self, $bref) = @_;
	my ($qsp, $di) = delete @$self{qw(-qsp -cur_di)};
	if (my $err = $qsp->{err}) {
		die "git ls-files error: $err";
	}

	my ($line, @extra) = split(/\0/, $$bref);
	scalar(@extra) and die "BUG: extra files in index: <",
				join('> <', @extra), ">";

	my ($info, $file) = split(/\t/, $line, 2);
	my ($mode_b, $oid_b_full, $stage) = split(/ /, $info);
	if ($file ne $di->{path_b}) {
		die
"BUG: index mismatch: file=$file != path_b=$di->{path_b}";
	}

	my $tmp_git = $self->{tmp_git} or die 'no git working tree';
	my (undef, undef, $size) = $tmp_git->check($oid_b_full);
	defined($size) or die "check $oid_b_full failed";

	dbg($self, "index at:\n$mode_b $oid_b_full\t$file");
	my $created = [ $tmp_git, $oid_b_full, 'blob', $size, $di ];
	mark_found($self, $di->{oid_b}, $created);
	next_step($self); # onto the next patch
}

sub ls_files_result {
	my ($bref, $self) = @_;
	eval { parse_ls_files($self, $bref) };
	ERR($self, $@) if $@;
}

sub oids_same_ish ($$) {
	(index($_[0], $_[1]) == 0) || (index($_[1], $_[0]) == 0);
}

sub skip_identical ($$$) {
	my ($self, $patches, $cur_oid_b) = @_;
	while (my $nxt = $patches->[0]) {
		if (oids_same_ish($cur_oid_b, $nxt->{oid_b})) {
			dbg($self, 'skipping '.di_url($self, $nxt).
				" for $cur_oid_b");
			shift @$patches;
		} else {
			return;
		}
	}
}

sub apply_result ($$) {
	my ($bref, $self) = @_;
	my ($qsp, $di) = delete @$self{qw(-qsp -cur_di)};
	dbg($self, $$bref);
	my $patches = $self->{patches};
	if (my $err = $qsp->{err}) {
		my $msg = "git apply error: $err";
		my $nxt = $patches->[0];
		if ($nxt && oids_same_ish($nxt->{oid_b}, $di->{oid_b})) {
			dbg($self, $msg);
			dbg($self, 'trying '.di_url($self, $nxt));
			return do_git_apply($self);
		} else {
			ERR($self, $msg);
		}
	} else {
		skip_identical($self, $patches, $di->{oid_b});
	}

	my @cmd = qw(git ls-files -s -z);
	$qsp = PublicInbox::Qspawn->new(\@cmd, $self->{git_env});
	$self->{-cur_di} = $di;
	$self->{-qsp} = $qsp;
	$qsp->psgi_qx($self->{psgi_env}, undef, \&ls_files_result, $self);
}

sub do_git_apply ($) {
	my ($self) = @_;
	my $dn = $self->{tmp}->dirname;
	my $patches = $self->{patches};

	# we need --ignore-whitespace because some patches are CRLF
	my @cmd = (qw(git apply --cached --ignore-whitespace
			--unidiff-zero --whitespace=warn --verbose));
	my $len = length(join(' ', @cmd));
	my $total = $self->{tot};
	my $di; # keep track of the last one for "git ls-files"
	my $prv_oid_b;

	do {
		my $i = ++$self->{nr};
		$di = shift @$patches;
		dbg($self, "\napplying [$i/$total] " . di_url($self, $di) .
			"\n" . $di->{hdr_lines});
		my $path = $di->{n};
		$len += length($path) + 1;
		push @cmd, $path;
		$prv_oid_b = $di->{oid_b};
	} while (@$patches && $len < $ARG_SIZE_MAX &&
		 !oids_same_ish($patches->[0]->{oid_b}, $prv_oid_b));

	my $opt = { 2 => 1, -C => $dn, quiet => 1 };
	my $qsp = PublicInbox::Qspawn->new(\@cmd, $self->{git_env}, $opt);
	$self->{-cur_di} = $di;
	$self->{-qsp} = $qsp;
	$qsp->psgi_qx($self->{psgi_env}, undef, \&apply_result, $self);
}

sub di_url ($$) {
	my ($self, $di) = @_;
	# note: we don't pass the PSGI env unconditionally, here,
	# different inboxes can have different HTTP_HOST on the same instance.
	my $ibx = $di->{ibx};
	my $env = $self->{psgi_env} if $ibx eq $self->{inboxes}->[0];
	my $url = $ibx->base_url($env);
	my $mid = $di->{smsg}->{mid};
	defined($url) ? "$url$mid/" : "<$mid>";
}

sub retry_current {
	my ($self, $want) = @_;
	push @{$self->{todo}}, $want;
	next_step($self); # retry solve_existing
}

sub try_harder ($$) {
	my ($self, $want) = @_;

	# do we have more inboxes to try?
	return retry_current($self, $want) if scalar @{$want->{try_ibxs}};

	my $cur_want = $want->{oid_b};
	if (length($cur_want) > $OID_MIN) { # maybe a shorter OID will work
		delete $want->{try_ibxs}; # drop empty arrayref
		chop($cur_want);
		dbg($self, "retrying $want->{oid_b} as $cur_want");
		$want->{oid_b} = $cur_want;
		return retry_current($self, $want); # retry with shorter abbrev
	}

	dbg($self, "could not find $cur_want");
	eval { done($self, undef) };
	die "E: $@" if $@;
}

sub extract_diffs_done {
	my ($self, $want) = @_;

	delete $want->{try_smsgs};
	delete $want->{cur_ibx};

	my $diffs = delete $self->{tmp_diffs};
	if (scalar @$diffs) {
		unshift @{$self->{patches}}, @$diffs;
		dbg($self, "found $want->{oid_b} in " .  join(" ||\n\t",
			map { di_url($self, $_) } @$diffs));

		# good, we can find a path to the oid we $want, now
		# lets see if we need to apply more patches:
		my $di = $diffs->[0];
		my $src = $di->{oid_a};

		unless ($src =~ /\A0+\z/) {
			# we have to solve it using another oid, fine:
			my $job = { oid_b => $src, path_b => $di->{path_a} };
			push @{$self->{todo}}, $job;
		}
		return next_step($self); # onto the next todo item
	}
	try_harder($self, $want);
}

sub extract_diff_async {
	my ($bref, $oid, $type, $size, $x) = @_;
	my ($self, $want, $smsg) = @$x;
	if (defined($oid)) {
		$smsg->{blob} eq $oid or
				ERR($self, "BUG: $smsg->{blob} != $oid");
		PublicInbox::Eml->new($bref)->each_part(\&extract_diff, $x, 1);
	}

	scalar(@{$want->{try_smsgs}}) ? retry_current($self, $want)
					: extract_diffs_done($self, $want);
}

sub resolve_patch ($$) {
	my ($self, $want) = @_;

	my $cur_want = $want->{oid_b};
	if (scalar(@{$self->{patches}}) > $MAX_PATCH) {
		die "Aborting, too many steps to $self->{oid_want}";
	}

	if (my $msgs = $want->{try_smsgs}) {
		my $smsg = shift @$msgs;
		if ($self->{psgi_env}->{'pi-httpd.async'}) {
			return ibx_async_cat($want->{cur_ibx}, $smsg->{blob},
						\&extract_diff_async,
						[$self, $want, $smsg]);
		} else {
			if (my $eml = $want->{cur_ibx}->smsg_eml($smsg)) {
				$eml->each_part(\&extract_diff,
						[ $self, $want, $smsg ], 1);
			}
		}

		return scalar(@$msgs) ? retry_current($self, $want)
					: extract_diffs_done($self, $want);
	}

	# see if we can find the blob in an existing git repo:
	if (!$want->{try_ibxs} && $self->{seen_oid}->{$cur_want}++) {
		die "Loop detected solving $cur_want\n";
	}
	$want->{try_ibxs} //= [ @{$self->{inboxes}} ]; # array copy
	my $existing = solve_existing($self, $want);
	if (ref $existing) {
		my ($found_git, undef, $type, undef) = @$existing;
		dbg($self, "found $cur_want in " .
			join(" ||\n\t",
				$found_git->pub_urls($self->{psgi_env})));

		if ($cur_want eq $self->{oid_want} || $type ne 'blob') {
			eval { done($self, $existing) };
			die "E: $@" if $@;
			return;
		}
		mark_found($self, $cur_want, $existing);
		return next_step($self); # onto patch application
	} elsif ($existing > 0) {
		return retry_current($self, $want);
	} else { # $existing == 0: we may retry if inbox scan (below) fails
		delete $want->{try_gits};
	}

	# scan through inboxes to look for emails which results in
	# the oid we want:
	my $ibx = shift(@{$want->{try_ibxs}}) or die 'BUG: {try_ibxs} empty';
	if (my $msgs = find_smsgs($self, $ibx, $want)) {
		$want->{try_smsgs} = $msgs;
		$want->{cur_ibx} = $ibx;
		$self->{tmp_diffs} = [];
		return retry_current($self, $want);
	}
	try_harder($self, $want);
}

# this API is designed to avoid creating self-referential structures;
# so user_cb never references the SolverGit object
sub new {
	my ($class, $ibx, $user_cb, $uarg) = @_;

	bless {
		gits => $ibx->{-repo_objs},
		user_cb => $user_cb,
		uarg => $uarg,
		# -cur_di, -qsp, -msg => temporary fields for Qspawn callbacks

		# TODO: config option for searching related inboxes
		inboxes => [ $ibx ],
	}, $class;
}

# recreate $oid_want using $hints
# hints keys: path_a, path_b, oid_a (note: `oid_b' is NOT a hint)
# Calls {user_cb} with: [ ::Git object, oid_full, type, size, di (diff_info) ]
# with found object, or undef if nothing was found
# Calls {user_cb} with a string error on fatal errors
sub solve ($$$$$) {
	my ($self, $env, $out, $oid_want, $hints) = @_;

	# should we even get here? Probably not, but somebody
	# could be manually typing URLs:
	return done($self, undef) if $oid_want =~ /\A0+\z/;

	$self->{oid_want} = $oid_want;
	$self->{out} = $out;
	$self->{seen_oid} = {};
	$self->{tot} = 0;
	$self->{psgi_env} = $env;
	$self->{todo} = [ { %$hints, oid_b => $oid_want } ];
	$self->{patches} = []; # [ $di, $di, ... ]
	$self->{found} = {}; # { abbr => [ ::Git, oid, type, size, $di ] }
	$self->{tmp} = File::Temp->newdir("solver.$oid_want-XXXX", TMPDIR => 1);

	dbg($self, "solving $oid_want ...");
	if (my $async = $env->{'pi-httpd.async'}) {
		# PublicInbox::HTTPD::Async->new
		$async->(undef, undef, $self);
	} else {
		event_step($self) while $self->{user_cb};
	}
}

1;
