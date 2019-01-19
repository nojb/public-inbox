# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "Solve" blobs which don't exist in git code repositories by
# searching inboxes for post-image blobs.

# this emits a lot of debugging/tracing information which may be
# publically viewed over HTTP(S).  Be careful not to expose
# local filesystem layouts in the process.
package PublicInbox::SolverGit;
use strict;
use warnings;
use File::Temp qw();
use Fcntl qw(SEEK_SET);
use PublicInbox::Git qw(git_unquote git_quote);
use PublicInbox::Spawn qw(spawn popen_rd);
use PublicInbox::MsgIter qw(msg_iter msg_part_text);
use URI::Escape qw(uri_escape_utf8);

# don't bother if somebody sends us a patch with these path components,
# it's junk at best, an attack attempt at worse:
my %bad_component = map { $_ => 1 } ('', '.', '..');

sub new {
	my ($class, $gits, $inboxes) = @_;
	bless {
		gits => $gits,
		inboxes => $inboxes,
	}, $class;
}

# look for existing blobs already in git repos
sub solve_existing ($$$) {
	my ($self, $out, $want) = @_;
	my $oid_b = $want->{oid_b};
	my @ambiguous; # Array of [ git, $oids]
	foreach my $git (@{$self->{gits}}) {
		my ($oid_full, $type, $size) = $git->check($oid_b);
		if (defined($type) && $type eq 'blob') {
			return [ $git, $oid_full, $type, int($size) ];
		}

		next if length($oid_b) == 40;

		# parse stderr of "git cat-file --batch-check"
		my $err = $git->last_check_err;
		my (@oids) = ($err =~ /\b([a-f0-9]{40})\s+blob\b/g);
		next unless scalar(@oids);

		# TODO: do something with the ambiguous array?
		# push @ambiguous, [ $git, @oids ];

		print $out "`$oid_b' ambiguous in ",
				join("\n", $git->pub_urls), "\n",
				join('', map { "$_ blob\n" } @oids), "\n";
	}
	scalar(@ambiguous) ? \@ambiguous : undef;
}

# returns a hashref with information about a diff ($di):
# {
#	oid_a => abbreviated pre-image oid,
#	oid_b => abbreviated post-image oid,
#	tmp => anonymous file handle with the diff,
#	hdr_lines => arrayref of various header lines for mode information
#	mode_a => original mode of oid_a (string, not integer),
#	ibx => PublicInbox::Inbox object containing the diff
#	smsg => PublicInbox::SearchMsg object containing diff
#	path_a => pre-image path
#	path_b => post-image path
# }
sub extract_diff ($$$$) {
	my ($p, $re, $ibx, $smsg) = @_;
	my ($part) = @$p; # ignore $depth and @idx;
	my $hdr_lines; # diff --git a/... b/...
	my $tmp;
	my $ct = $part->content_type || 'text/plain';
	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;
	my $di = {};
	foreach my $l (split(/^/m, $s)) {
		if ($l =~ $re) {
			$di->{oid_a} = $1;
			$di->{oid_b} = $2;
			if (defined($3)) {
				my $mode_a = $3;
				if ($mode_a =~ /\A(?:100644|120000|100755)\z/) {
					$di->{mode_a} = $mode_a;
				}
			}

			# start writing the diff out to a tempfile
			open($tmp, '+>', undef) or die "open(tmp): $!";
			$di->{tmp} = $tmp;

			push @$hdr_lines, $l;
			$di->{hdr_lines} = $hdr_lines;
			print $tmp @$hdr_lines, $l or die "print(tmp): $!";

			# for debugging/diagnostics:
			$di->{ibx} = $ibx;
			$di->{smsg} = $smsg;
		} elsif ($l =~ m!\Adiff --git ("?a/.+) ("?b/.+)$!) {
			return $di if $tmp; # got our blob, done!

			my ($path_a, $path_b) = ($1, $2);

			# don't care for leading 'a/' and 'b/'
			my (undef, @a) = split(m{/}, git_unquote($path_a));
			my (undef, @b) = split(m{/}, git_unquote($path_b));

			# get rid of path-traversal attempts and junk patches:
			foreach (@a, @b) {
				return if $bad_component{$_};
			}

			$di->{path_a} = join('/', @a);
			$di->{path_b} = join('/', @b);
			$hdr_lines = [ $l ];
		} elsif ($tmp) {
			print $tmp $l or die "print(tmp): $!";
		} elsif ($hdr_lines) {
			push @$hdr_lines, $l;
			if ($l =~ /\Anew file mode (100644|120000|100755)$/) {
				$di->{mode_a} = $1;
			}
		}
	}
	$tmp ? $di : undef;
}

sub path_searchable ($) { defined($_[0]) && $_[0] =~ m!\A[\w/\. \-]+\z! }

sub find_extract_diff ($$$) {
	my ($self, $ibx, $want) = @_;
	my $srch = $ibx->search or return;

	my $post = $want->{oid_b} or die 'BUG: no {oid_b}';
	$post =~ /\A[a-f0-9]+\z/ or die "BUG: oid_b not hex: $post";

	my $q = "dfpost:$post";
	my $pre = $want->{oid_a};
	if (defined $pre && $pre =~ /\A[a-f0-9]+\z/) {
		$q .= " dfpre:$pre";
	} else {
		$pre = '[a-f0-9]{7}'; # for $re below
	}

	my $path_b = $want->{path_b};
	if (path_searchable($path_b)) {
		$q .= qq{ dfn:"$path_b"};

		my $path_a = $want->{path_a};
		if (path_searchable($path_a) && $path_a ne $path_b) {
			$q .= qq{ dfn:"$path_a"};
		}
	}

	my $msgs = $srch->query($q, { relevance => 1 });
	my $re = qr/\Aindex ($pre[a-f0-9]*)\.\.($post[a-f0-9]*)(?: (\d+))?/;

	my $di;
	foreach my $smsg (@$msgs) {
		$ibx->smsg_mime($smsg) or next;
		msg_iter(delete($smsg->{mime}), sub {
			$di ||= extract_diff($_[0], $re, $ibx, $smsg);
		});
		return $di if $di;
	}
}

# pure Perl "git init"
sub do_git_init_wt ($) {
	my ($self) = @_;
	my $wt = File::Temp->newdir('solver.wt-XXXXXXXX', TMPDIR => 1);
	my $dir = $wt->dirname;

	foreach ('', qw(objects refs objects/info refs/heads)) {
		mkdir("$dir/.git/$_") or die "mkdir $_: $!";
	}
	open my $fh, '>', "$dir/.git/config" or die "open .git/config: $!";
	print $fh <<'EOF' or die "print .git/config $!";
[core]
	repositoryFormatVersion = 0
	filemode = true
	bare = false
	fsyncObjectfiles = false
	logAllRefUpdates = false
EOF
	close $fh or die "close .git/config: $!";

	open $fh, '>', "$dir/.git/HEAD" or die "open .git/HEAD: $!";
	print $fh "ref: refs/heads/master\n" or die "print .git/HEAD: $!";
	close $fh or die "close .git/HEAD: $!";

	my $f = '.git/objects/info/alternates';
	open $fh, '>', "$dir/$f" or die "open: $f: $!";
	print($fh (map { "$_->{git_dir}/objects\n" } @{$self->{gits}})) or
		die "print $f: $!";
	close $fh or die "close: $f: $!";
	$wt;
}

sub extract_old_mode ($) {
	my ($di) = @_;
	if (grep(/\Aold mode (100644|100755|120000)$/, @{$di->{hdr_lines}})) {
		return $1;
	}
	'100644';
}

sub reap ($$) {
	my ($pid, $msg) = @_;
	waitpid($pid, 0) == $pid or die "waitpid($msg): $!";
	$? == 0 or die "$msg failed: $?";
}

sub prepare_index ($$$$) {
	my ($out, $wt_dir, $existing, $di) = @_;
	my $oid_full = $existing->[1];
	my ($r, $w);
	my $path_a = $di->{path_a} or die "BUG: path_a missing for $oid_full";
	my $mode_a = $di->{mode_a} || extract_old_mode($di);
	my @git = (qw(git -C), $wt_dir);

	pipe($r, $w) or die "pipe: $!";
	my $rdr = { 0 => fileno($r) };
	my $pid = spawn([@git, qw(update-index -z --index-info)], {}, $rdr);
	close $r or die "close pipe(r): $!";
	print $w "$mode_a $oid_full\t$path_a\0" or die "print update-index: $!";

	close $w or die "close update-index: $!";
	reap($pid, 'update-index -z --index-info');

	print $out "index prepared:\n",
		"$mode_a $oid_full\t", git_quote($path_a), "\n";
}

sub do_apply_begin ($$$) {
	my ($out, $wt_dir, $di) = @_;

	my $tmp = delete $di->{tmp} or die "BUG: no tmp ", di_url($di);
	$tmp->flush or die "tmp->flush failed: $!";
	$out->flush or die "err->flush failed: $!";
	sysseek($tmp, 0, SEEK_SET) or die "sysseek(tmp) failed: $!";

	defined(my $err_fd = fileno($out)) or die "fileno(out): $!";
	my $rdr = { 0 => fileno($tmp), 1 => $err_fd, 2 => $err_fd };
	my $cmd = [ qw(git -C), $wt_dir,
	            qw(apply --cached --whitespace=warn --verbose) ];
	spawn($cmd, undef, $rdr);
}

sub do_apply_continue ($$) {
	my ($wt_dir, $apply_pid) = @_;
	reap($apply_pid, 'apply');
	popen_rd([qw(git -C), $wt_dir, qw(ls-files -s -z)]);
}

sub do_apply_end ($$$$) {
	my ($out, $wt_git, $rd, $di) = @_;

	local $/ = "\0";
	defined(my $line = <$rd>) or die "failed to read ls-files: $!";
	chomp $line or die "no trailing \\0 in [$line] from ls-files";

	my ($info, $file) = split(/\t/, $line, 2);
	my ($mode_b, $oid_b_full, $stage) = split(/ /, $info);

	defined($line = <$rd>) and die "extra files in index: $line";
	close $rd or die "close ls-files: $?";

	$file eq $di->{path_b} or
		die "index mismatch: file=$file != path_b=$di->{path_b}";

	my (undef, undef, $size) = $wt_git->check($oid_b_full);

	defined($size) or die "failed to read_size from $oid_b_full";

	print $out "$mode_b $oid_b_full\t$file\n";
	[ $wt_git, $oid_b_full, 'blob', $size, $di ];
}

sub di_url ($) {
	my ($di) = @_;
	# note: we don't pass the PSGI env here, different inboxes
	# can have different HTTP_HOST on the same instance.
	my $url = $di->{ibx}->base_url;
	my $mid = $di->{smsg}->{mid};
	defined($url) ? "$url$mid/" : "<$mid>";
}

# reconstruct the oid_b blob using patches we found:
sub apply_patches_cb ($$$$$) {
	my ($self, $out, $found, $patches, $oid_b) = @_;

	my $tot = scalar(@$patches) or return sub {
		print $out "no patch(es) for $oid_b\n";
		undef;
	};

	my $wt = do_git_init_wt($self);
	my $wt_dir = $wt->dirname;
	my $wt_git = PublicInbox::Git->new("$wt_dir/.git");
	$wt_git->{-wt} = $wt;

	my $cur = 0;
	my ($apply_pid, $rd, $di);

	# returns an empty string if in progress, undef if not found,
	# or the final [ ::Git, oid_full, type, size, $di ] arrayref
	# if found
	sub {
		if ($rd) {
			$found->{$di->{oid_b}} =
					do_apply_end($out, $wt_git, $rd, $di);
			$rd = undef;
			# continue to shift @$patches
		} elsif ($apply_pid) {
			$rd = do_apply_continue($wt_dir, $apply_pid);
			$apply_pid = undef;
			return ''; # $rd => do_apply_ned
		}

		# may return undef here
		$di = shift @$patches or return $found->{$oid_b};

		my $i = ++$cur;
		my $oid_a = $di->{oid_a};
		my $existing = $found->{$oid_a};
		my $empty_oid = $oid_a =~ /\A0+\z/;

		if ($empty_oid && $i != 1) {
			die "empty oid at [$i/$tot] ", di_url($di);
		}
		if (!$existing && !$empty_oid) {
			die "missing $oid_a at [$i/$tot] ", di_url($di);
		}

		# prepare the worktree for patch application:
		if ($i == 1 && $existing) {
			prepare_index($out, $wt_dir, $existing, $di);
		}

		print $out "\napplying [$i/$tot] ", di_url($di), "\n",
			   join('', @{$di->{hdr_lines}}), "\n"
			or die "print \$out failed: $!";

		# begin the patch application patch!
		$apply_pid = do_apply_begin($out, $wt_dir, $di);
		# next call to this callback will call do_apply_continue
		'';
	}
}

# recreate $oid_b
# Returns an array ref: [ ::Git object, oid_full, type, size, di ]
# or undef if nothing was found.
sub solve ($$$$) {
	my ($self, $out, $oid_b, $hints) = @_;

	# should we even get here? Probably not, but somebody
	# could be manually typing URLs:
	return if $oid_b =~ /\A0+\z/;

	my $req = { %$hints, oid_b => $oid_b };
	my @todo = ($req);
	my $found = {}; # { abbrev => [ ::Git, oid_full, type, size, $di ] }
	my $patches = []; # [ array of $di hashes ]
	my $max = $self->{max_patches} || 200;
	my $apply_cb;
	my $cb = sub {
		my $want = pop @todo;
		unless ($want) {
			$apply_cb ||= apply_patches_cb($self, $out, $found,
			                               $patches, $oid_b);
			return $apply_cb->();
		}

		if (scalar(@$patches) > $max) {
			print $out "Aborting, too many steps to $oid_b\n";
			return;
		}
		# see if we can find the blob in an existing git repo:
		my $want_oid = $want->{oid_b};
		if (my $existing = solve_existing($self, $out, $want)) {
			print $out "found $want_oid in ",
				join("\n", $existing->[0]->pub_urls), "\n";

			return $existing if $want_oid eq $oid_b; # DONE!
			$found->{$want_oid} = $existing;
			return ''; # ok, one blob resolved, more to go?
		}

		# scan through inboxes to look for emails which results in
		# the oid we want:
		my $di;
		foreach my $ibx (@{$self->{inboxes}}) {
			$di = find_extract_diff($self, $ibx, $want) or next;

			unshift @$patches, $di;
			print $out "found $want_oid in ",di_url($di),"\n";

			# good, we can find a path to the oid we $want, now
			# lets see if we need to apply more patches:
			my $src = $di->{oid_a};

			last if $src =~ /\A0+\z/;

			# we have to solve it using another oid, fine:
			my $job = { oid_b => $src, path_b => $di->{path_a} };
			push @todo, $job;
			last; # onto the next @todo item
		}
		unless ($di) {
			print $out "$want_oid could not be found\n";
			return;
		}
		''; # continue onto next @todo item;
	};

	while (1) {
		my $ret = $cb->();
		return $ret if (ref($ret) || !defined($ret));
		# $ret == ''; so continue looping here
	}
}

1;
