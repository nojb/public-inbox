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

# returns a hashref with information about a diff:
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

sub prepare_wt ($$$$) {
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

	$pid = spawn([@git, qw(checkout-index -a -f -u)]);
	reap($pid, 'checkout-index -a -f -u');

	print $out "Working tree prepared:\n",
		"$mode_a $oid_full\t", git_quote($path_a), "\n";
}

sub do_apply ($$$$) {
	my ($out, $wt_git, $wt_dir, $di) = @_;

	my $tmp = delete $di->{tmp} or die "BUG: no tmp ", di_url($di);
	$tmp->flush or die "tmp->flush failed: $!";
	$out->flush or die "err->flush failed: $!";
	sysseek($tmp, 0, SEEK_SET) or die "sysseek(tmp) failed: $!";

	defined(my $err_fd = fileno($out)) or die "fileno(out): $!";
	my $rdr = { 0 => fileno($tmp), 1 => $err_fd, 2 => $err_fd };
	my $cmd = [ qw(git -C), $wt_dir,
	            qw(apply --whitespace=warn -3 --verbose) ];
	reap(spawn($cmd, undef, $rdr), 'apply');

	local $/ = "\0";
	my $rd = popen_rd([qw(git -C), $wt_dir, qw(ls-files -s -z)]);

	defined(my $line = <$rd>) or die "failed to read ls-files: $!";
	chomp $line or die "no trailing \\0 in [$line] from ls-files";

	my ($info, $file) = split(/\t/, $line, 2);
	my ($mode_b, $oid_b_full, $stage) = split(/ /, $info);

	defined($line = <$rd>) and die "extra files in index: $line";
	close $rd or die "close ls-files: $?";

	$file eq $di->{path_b} or
		die "index mismatch: file=$file != path_b=$di->{path_b}";
	my $abs_path = "$wt_dir/$file";
	-r $abs_path or die "WT_DIR/$file not readable";
	my $size = -s _;

	print $out "OK $mode_b $oid_b_full $stage\t$file\n";
	[ $wt_git, $oid_b_full, 'blob', $size, $di ];
}

sub di_url ($) {
	my ($di) = @_;
	# note: we don't pass the PSGI env here, different inboxes
	# can have different HTTP_HOST on the same instance.
	my $url = $di->{ibx}->base_url;
	my $mid = $di->{smsg}->{mid};
	defined($url) ? "<$url$mid/>" : "<$mid>";
}

sub apply_patches ($$$$$) {
	my ($self, $out, $wt, $found, $patches) = @_;
	my $wt_dir = $wt->dirname;
	my $wt_git = PublicInbox::Git->new("$wt_dir/.git");
	$wt_git->{-wt} = $wt;

	my $cur = 0;
	my $tot = scalar @$patches;

	foreach my $di (@$patches) {
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
			prepare_wt($out, $wt_dir, $existing, $di);
		}
		if (!$empty_oid && ! -f "$wt_dir/$di->{path_a}") {
			die "missing $di->{path_a} at [$i/$tot] ", di_url($di);
		}

		print $out "\napplying [$i/$tot] ", di_url($di), "\n",
			   join('', @{$di->{hdr_lines}}), "\n"
			or die "print \$out failed: $!";

		# apply the patch!
		$found->{$di->{oid_b}} = do_apply($out, $wt_git, $wt_dir, $di);
	}
}

sub dump_found ($$) {
	my ($out, $found) = @_;
	foreach my $oid (sort keys %$found) {
		my ($git, $oid, undef, undef, $di) = @{$found->{$oid}};
		my $loc = $di ? di_url($di) : $git->src_blob_url($oid);
		print $out "$oid from $loc\n";
	}
}

sub dump_patches ($$) {
	my ($out, $patches) = @_;
	my $tot = scalar(@$patches);
	my $i = 0;
	foreach my $di (@$patches) {
		++$i;
		print $out "[$i/$tot] ", di_url($di), "\n";
	}
}

# recreate $oid_b
# Returns a 2-element array ref: [ PublicInbox::Git object, oid_full ]
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

	my $max = $self->{max_steps} || 200;
	my $steps = 0;

	while (defined(my $want = pop @todo)) {
		# see if we can find the blob in an existing git repo:
		if (my $existing = solve_existing($self, $out, $want)) {
			my $want_oid = $want->{oid_b};
			if ($want_oid eq $oid_b) { # DONE!
				my @pub_urls = $existing->[0]->pub_urls;
				print $out "found $want_oid in ",
						join("\n", @pub_urls),"\n";
				return $existing;
			}

			$found->{$want_oid} = $existing;
			next; # ok, one blob resolved, more to go?
		}

		# scan through inboxes to look for emails which results in
		# the oid we want:
		foreach my $ibx (@{$self->{inboxes}}) {
			my $di = find_extract_diff($self, $ibx, $want) or next;

			unshift @$patches, $di;

			# good, we can find a path to the oid we $want, now
			# lets see if we need to apply more patches:
			my $src = $di->{oid_a};
			if ($src !~ /\A0+\z/) {
				if (++$steps > $max) {
					print $out
"Aborting, too many steps to $oid_b\n";

					return;
				}

				# we have to solve it using another oid, fine:
				my $job = {
					oid_b => $src,
					path_b => $di->{path_a},
				};
				push @todo, $job;
			}
			last; # onto the next @todo item
		}
	}

	unless (scalar(@$patches)) {
		print $out "no patch(es) for $oid_b\n";
		dump_found($out, $found);
		return;
	}

	# reconstruct the oid_b blob using patches we found:
	eval {
		my $wt = do_git_init_wt($self);
		apply_patches($self, $out, $wt, $found, $patches);
	};
	if ($@) {
		print $out "E: $@\nfound: ";
		dump_found($out, $found);
		print $out "patches: ";
		dump_patches($out, $patches);
		return;
	}

	$found->{$oid_b};
}

1;
