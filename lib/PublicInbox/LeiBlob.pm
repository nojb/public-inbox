# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei blob $OID" command
# TODO: this doesn't scan submodules, but maybe it should
package PublicInbox::LeiBlob;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Spawn qw(spawn popen_rd which);
use PublicInbox::DS;

sub sol_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $sol = delete $lei->{sol} // return $lei->dclose; # already failed
	$sol->wq_wait_old($lei->can('wq_done_wait'), $lei);
}

sub get_git_dir ($$) {
	my ($lei, $d) = @_;
	return $d if -d "$d/objects" && -d "$d/refs" && -e "$d/HEAD";

	my $cmd = [ qw(git rev-parse --git-dir) ];
	my $opt = { '-C' => $d };
	if (defined($lei->{opt}->{cwd})) { # --cwd used, report errors
		$opt->{2} = $lei->{2};
	} else { # implicit --cwd, quiet errors
		open $opt->{2}, '>', '/dev/null' or die "open /dev/null: $!";
	}
	my ($r, $pid) = popen_rd($cmd, {GIT_DIR => undef}, $opt);
	chomp(my $gd = do { local $/; <$r> });
	waitpid($pid, 0) == $pid or die "BUG: waitpid @$cmd ($!)";
	$? == 0 ? $gd : undef;
}

sub solver_user_cb { # called by solver when done
	my ($res, $self) = @_;
	my $lei = $self->{lei};
	my $log_buf = delete $lei->{'log_buf'};
	$$log_buf =~ s/^/# /sgm;
	ref($res) eq 'ARRAY' or return $lei->child_error(1 << 8, $$log_buf);
	$lei->qerr($$log_buf);
	my ($git, $oid, $type, $size, $di) = @$res;
	my $gd = $git->{git_dir};

	# don't try to support all the git-show(1) options for non-blob,
	# this is just a convenience:
	$type ne 'blob' and
		$lei->err("# $oid is a $type of $size bytes in:\n#\t$gd");

	my $cmd = [ 'git', "--git-dir=$gd", 'show', $oid ];
	my $rdr = { 1 => $lei->{1}, 2 => $lei->{2} };
	waitpid(spawn($cmd, $lei->{env}, $rdr), 0);
	$lei->child_error($?) if $?;
}

sub do_solve_blob { # via wq_do
	my ($self) = @_;
	my $lei = $self->{lei};
	my $git_dirs = $lei->{opt}->{'git-dir'};
	my $hints = {};
	for my $x (qw(oid-a path-a path-b)) {
		my $v = $lei->{opt}->{$x} // next;
		$x =~ tr/-/_/;
		$hints->{$x} = $v;
	}
	open my $log, '+>', \(my $log_buf = '') or die "PerlIO::scalar: $!";
	$lei->{log_buf} = \$log_buf;
	my $git = $lei->{ale}->git;
	my @rmt = map {
		PublicInbox::LeiRemote->new($lei, $_)
	} $self->{lxs}->remotes;
	my $solver = bless {
		gits => [ map {
				PublicInbox::Git->new($lei->rel2abs($_))
			} @$git_dirs ],
		user_cb => \&solver_user_cb,
		uarg => $self,
		# -cur_di, -qsp, -msg => temporary fields for Qspawn callbacks
		inboxes => [ $self->{lxs}->locals, @rmt ],
	}, 'PublicInbox::SolverGit';
	$lei->{env}->{'psgi.errors'} = $lei->{2}; # ugh...
	local $PublicInbox::DS::in_loop = 0; # waitpid synchronously
	$solver->solve($lei->{env}, $log, $self->{oid_b}, $hints);
}

sub cat_attach_i { # Eml->each_part callback
	my ($part, $depth, $idx) = @{$_[0]};
	my $lei = $_[1];
	my $want = $lei->{-attach_idx} // return;
	return if $idx ne $want; # [0-9]+(?:\.[0-9]+)+
	delete $lei->{-attach_idx};
	$lei->out($part->body);
}

sub lei_blob {
	my ($lei, $blob) = @_;
	$lei->start_pager if -t $lei->{1};
	my $opt = $lei->{opt};
	my $has_hints = grep(defined, @$opt{qw(oid-a path-a path-b)});
	my $lxs;
	if ($blob =~ s/:([0-9\.]+)\z//) {
		$lei->{-attach_idx} = $1;
		$opt->{mail} = 1;
	}

	# first, see if it's a blob returned by "lei q" JSON output:k
	if ($opt->{mail} // ($has_hints ? 0 : 1)) {
		if (grep(defined, @$opt{qw(include only)})) {
			$lxs = $lei->lxs_prepare;
			$lei->ale->refresh_externals($lxs);
		}
		my $rdr = {};
		if ($opt->{mail}) {
			$rdr->{2} = $lei->{2};
		} else {
			open $rdr->{2}, '>', '/dev/null' or die "open: $!";
		}
		my $cmd = [ 'git', '--git-dir='.$lei->ale->git->{git_dir},
				'cat-file', 'blob', $blob ];
		if (defined $lei->{-attach_idx}) {
			my $fh = popen_rd($cmd, $lei->{env}, $rdr);
			require PublicInbox::Eml;
			my $str = do { local $/; <$fh> };
			if (close $fh) {
				my $eml = PublicInbox::Eml->new(\$str);
				$eml->each_part(\&cat_attach_i, $lei, 1);
				my $idx = delete $lei->{-attach_idx};
				defined($idx) and return $lei->fail(<<EOM);
E: attachment $idx not found in $blob
EOM
			}
		} else {
			$rdr->{1} = $lei->{1};
			waitpid(spawn($cmd, $lei->{env}, $rdr), 0);
		}
		return if $? == 0;
		return $lei->child_error($?) if $opt->{mail};
	}

	# maybe it's a non-email (code) blob from a coderepo
	my $git_dirs = $opt->{'git-dir'} //= [];
	if ($opt->{'cwd'} // 1) {
		my $cgd = get_git_dir($lei, '.');
		unshift(@$git_dirs, $cgd) if defined $cgd;
	}
	return $lei->fail('no --git-dir to try') unless @$git_dirs;
	unless ($lxs) {
		$lxs = $lei->lxs_prepare or return;
		$lei->ale->refresh_externals($lxs);
	}
	if ($lxs->remotes) {
		require PublicInbox::LeiRemote;
		$lei->{curl} //= which('curl') or return
			$lei->fail('curl needed for', $lxs->remotes);
		$lei->_lei_store(1)->write_prepare($lei);
	}
	require PublicInbox::SolverGit;
	my $self = bless { lxs => $lxs, oid_b => $blob }, __PACKAGE__;
	my ($op_c, $ops) = $lei->workers_start($self, 'lei_solve', 1,
		{ '' => [ \&sol_done, $lei ] });
	$lei->{sol} = $self;
	$self->wq_io_do('do_solve_blob', []);
	$self->wq_close(1);
	$op_c->op_wait_event($ops);
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->_lei_atfork_child;
	$SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$self->SUPER::ipc_atfork_child;
}

1;
