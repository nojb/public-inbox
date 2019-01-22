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
use PublicInbox::Qspawn;
use URI::Escape qw(uri_escape_utf8);

# di = diff info / a hashref with information about a diff ($di):
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

# don't bother if somebody sends us a patch with these path components,
# it's junk at best, an attack attempt at worse:
my %bad_component = map { $_ => 1 } ('', '.', '..');

sub dbg ($$) {
	print { $_[0]->{out} } $_[1], "\n" or ERR($_[0], "print(dbg): $!");
}

sub ERR ($$) {
	my ($self, $err) = @_;
	print { $self->{out} } $err, "\n";
	my $ucb = delete($self->{user_cb});
	eval { $ucb->($err) } if $ucb;
	die $err;
}

# look for existing blobs already in git repos
sub solve_existing ($$) {
	my ($self, $want) = @_;
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

		dbg($self, "`$oid_b' ambiguous in " .
				join("\n\t", $git->pub_urls) . "\n" .
				join('', map { "$_ blob\n" } @oids));
	}
	scalar(@ambiguous) ? \@ambiguous : undef;
}

sub extract_diff ($$$$) {
	my ($p, $re, $ibx, $smsg) = @_;
	my ($part) = @$p; # ignore $depth and @idx;
	my $hdr_lines; # diff --git a/... b/...
	my $tmp;
	my $ct = $part->content_type || 'text/plain';
	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;
	my $di = {};

	# Email::MIME::Encodings forces QP to be CRLF upon decoding,
	# change it back to LF:
	my $cte = $part->header('Content-Transfer-Encoding') || '';
	if ($cte =~ /\bquoted-printable\b/i && $part->crlf eq "\n") {
		$s =~ s/\r\n/\n/sg;
	}

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
			print $tmp @$hdr_lines or die "print(tmp): $!";

			# for debugging/diagnostics:
			$di->{ibx} = $ibx;
			$di->{smsg} = $smsg;
		} elsif ($l =~ m!\Adiff --git ("?a/.+) ("?b/.+)$!) {
			return $di if $tmp; # got our blob, done!

			my ($path_a, $path_b) = ($1, $2);

			# diff header lines won't have \r because git
			# will quote them, but Email::MIME gives CRLF
			# for quoted-printable:
			$path_b =~ tr/\r//d;

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

sub prepare_index ($) {
	my ($self) = @_;
	my $patches = $self->{patches};
	$self->{nr} = 0;
	$self->{tot} = scalar @$patches;

	my $di = $patches->[0] or die 'no patches';
	my $oid_a = $di->{oid_a} or die '{oid_a} unset';
	my $existing = $self->{found}->{$oid_a};

	# no index creation for added files
	$oid_a =~ /\A0+\z/ and return next_step($self);

	die "BUG: $oid_a not not found" unless $existing;

	my $oid_full = $existing->[1];
	my $path_a = $di->{path_a} or die "BUG: path_a missing for $oid_full";
	my $mode_a = $di->{mode_a} || extract_old_mode($di);

	open my $in, '+>', undef or die "open: $!";
	print $in "$mode_a $oid_full\t$path_a\0" or die "print: $!";
	$in->flush or die "flush: $!";
	sysseek($in, 0, 0) or die "seek: $!";

	dbg($self, 'preparing index');
	my $rdr = { 0 => fileno($in) };
	my $cmd = [ qw(git -C), $self->{wt_dir},
			qw(update-index -z --index-info) ];
	my $qsp = PublicInbox::Qspawn->new($cmd, undef, $rdr);
	$qsp->psgi_qx($self->{psgi_env}, undef, sub {
		my ($bref) = @_;
		if (my $err = $qsp->{err}) {
			ERR($self, "git update-index error: $err");
		}
		dbg($self, "index prepared:\n" .
			"$mode_a $oid_full\t" . git_quote($path_a));
		next_step($self); # onto do_git_apply
	});
}

# pure Perl "git init"
sub do_git_init_wt ($) {
	my ($self) = @_;
	my $wt = File::Temp->newdir('solver.wt-XXXXXXXX', TMPDIR => 1);
	my $dir = $self->{wt_dir} = $wt->dirname;

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
	my $wt_git = $self->{wt_git} = PublicInbox::Git->new("$dir/.git");
	$wt_git->{-wt} = $wt;
	prepare_index($self);
}

sub extract_old_mode ($) {
	my ($di) = @_;
	if (grep(/\Aold mode (100644|100755|120000)$/, @{$di->{hdr_lines}})) {
		return $1;
	}
	'100644';
}

sub do_step ($) {
	my ($self) = @_;
	eval {
		# step 1: resolve blobs to patches in the todo queue
		if (my $want = pop @{$self->{todo}}) {
			# this populates {patches} and {todo}
			resolve_patch($self, $want);

		# step 2: then we instantiate a working tree once
		# the todo queue is finally empty:
		} elsif (!defined($self->{wt_git})) {
			do_git_init_wt($self);

		# step 3: apply each patch in the stack
		} elsif (scalar @{$self->{patches}}) {
			do_git_apply($self);

		# step 4: execute the user-supplied callback with
		# our result: (which may be undef)
		# Other steps may call user_cb to terminate prematurely
		# on error
		} elsif (my $ucb = delete($self->{user_cb})) {
			$ucb->($self->{found}->{$self->{oid_want}});
		} else {
			die 'about to call user_cb twice'; # Oops :x
		}
	}; # eval
	my $err = $@;
	if ($err) {
		$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
		dbg($self, "E: $err");
		my $ucb = delete($self->{user_cb});
		eval { $ucb->($err) } if $ucb;
	}
}

sub step_cb ($) {
	my ($self) = @_;
	sub { do_step($self) };
}

sub next_step ($) {
	my ($self) = @_;
	# if outside of public-inbox-httpd, caller is expected to be
	# looping step_cb, anyways
	my $async = $self->{psgi_env}->{'pi-httpd.async'} or return;
	# PublicInbox::HTTPD::Async->new
	$async->(undef, step_cb($self));
}

sub mark_found ($$$) {
	my ($self, $oid, $found_info) = @_;
	$self->{found}->{$oid} = $found_info;
}

sub parse_ls_files ($$$$) {
	my ($self, $qsp, $bref, $di) = @_;
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

	my $wt_git = $self->{wt_git} or die 'no git working tree';
	my (undef, undef, $size) = $wt_git->check($oid_b_full);
	defined($size) or die "check $oid_b_full failed";

	dbg($self, "index at:\n$mode_b $oid_b_full\t$file");
	my $created = [ $wt_git, $oid_b_full, 'blob', $size, $di ];
	mark_found($self, $di->{oid_b}, $created);
	next_step($self); # onto the next patch
}

sub start_ls_files ($$) {
	my ($self, $di) = @_;
	my $cmd = [qw(git -C), $self->{wt_dir}, qw(ls-files -s -z)];
	my $qsp = PublicInbox::Qspawn->new($cmd);
	$qsp->psgi_qx($self->{psgi_env}, undef, sub {
		my ($bref) = @_;
		eval { parse_ls_files($self, $qsp, $bref, $di) };
		ERR($self, $@) if $@;
	});
}

sub do_git_apply ($) {
	my ($self) = @_;

	my $di = shift @{$self->{patches}} or die 'empty {patches}';
	my $tmp = delete $di->{tmp} or die 'no tmp ', di_url($self, $di);
	$tmp->flush or die "tmp->flush failed: $!";
	sysseek($tmp, 0, SEEK_SET) or die "sysseek(tmp) failed: $!";

	my $i = ++$self->{nr};
	dbg($self, "\napplying [$i/$self->{tot}] " . di_url($self, $di) .
		"\n" . join('', @{$di->{hdr_lines}}));

	# we need --ignore-whitespace because some patches are CRLF
	my $cmd = [ qw(git -C), $self->{wt_dir},
	            qw(apply --cached --ignore-whitespace
		       --whitespace=warn --verbose) ];
	my $rdr = { 0 => fileno($tmp), 2 => 1 };
	my $qsp = PublicInbox::Qspawn->new($cmd, undef, $rdr);
	$qsp->psgi_qx($self->{psgi_env}, undef, sub {
		my ($bref) = @_;
		close $tmp;
		dbg($self, $$bref);
		if (my $err = $qsp->{err}) {
			ERR($self, "git apply error: $err");
		}
		eval { start_ls_files($self, $di) };
		ERR($self, $@) if $@;
	});
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

sub resolve_patch ($$) {
	my ($self, $want) = @_;

	if (scalar(@{$self->{patches}}) > $self->{max_patch}) {
		die "Aborting, too many steps to $self->{oid_want}";
	}

	# see if we can find the blob in an existing git repo:
	my $cur_want = $want->{oid_b};
	if (my $existing = solve_existing($self, $want)) {
		dbg($self, "found $cur_want in " .
			join("\n", $existing->[0]->pub_urls));

		if ($cur_want eq $self->{oid_want}) { # all done!
			eval { delete($self->{user_cb})->($existing) };
			die "E: $@" if $@;
			return;
		}
		mark_found($self, $cur_want, $existing);
		return next_step($self); # onto patch application
	}

	# scan through inboxes to look for emails which results in
	# the oid we want:
	my $di;
	foreach my $ibx (@{$self->{inboxes}}) {
		$di = find_extract_diff($self, $ibx, $want) or next;

		unshift @{$self->{patches}}, $di;
		dbg($self, "found $cur_want in ".di_url($self, $di));

		# good, we can find a path to the oid we $want, now
		# lets see if we need to apply more patches:
		my $src = $di->{oid_a};

		unless ($src =~ /\A0+\z/) {
			# we have to solve it using another oid, fine:
			my $job = { oid_b => $src, path_b => $di->{path_a} };
			push @{$self->{todo}}, $job;
		}
		return next_step($self); # onto the next todo item
	}
	dbg($self, "could not find $cur_want");
	eval { delete($self->{user_cb})->(undef) }; # not found! :<
	die "E: $@" if $@;
}

# this API is designed to avoid creating self-referential structures;
# so user_cb never references the SolverGit object
sub new {
	my ($class, $ibx, $user_cb) = @_;

	bless {
		gits => $ibx->{-repo_objs},
		user_cb => $user_cb,
		max_patch => 100,

		# TODO: config option for searching related inboxes
		inboxes => [ $ibx ],
	}, $class;
}

# recreate $oid_want using $hints
# Calls {user_cb} with: [ ::Git object, oid_full, type, size, di (diff_info) ]
# with found object, or undef if nothing was found
# Calls {user_cb} with a string error on fatal errors
sub solve ($$$$$) {
	my ($self, $env, $out, $oid_want, $hints) = @_;

	# should we even get here? Probably not, but somebody
	# could be manually typing URLs:
	return (delete $self->{user_cb})->(undef) if $oid_want =~ /\A0+\z/;

	$self->{oid_want} = $oid_want;
	$self->{out} = $out;
	$self->{psgi_env} = $env;
	$self->{todo} = [ { %$hints, oid_b => $oid_want } ];
	$self->{patches} = []; # [ $di, $di, ... ]
	$self->{found} = {}; # { abbr => [ ::Git, oid, type, size, $di ] }

	dbg($self, "solving $oid_want ...");
	my $step_cb = step_cb($self);
	if (my $async = $env->{'pi-httpd.async'}) {
		# PublicInbox::HTTPD::Async->new
		$async->(undef, $step_cb);
	} else {
		$step_cb->() while $self->{user_cb};
	}
}

1;
