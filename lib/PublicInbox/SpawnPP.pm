# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Pure-Perl implementation of "spawn".  This can't take advantage
# of vfork, so no speedups under Linux for spawning from large processes.
package PublicInbox::SpawnPP;
use strict;
use v5.10.1;
use POSIX qw(dup2 _exit setpgid :signal_h);

# Pure Perl implementation for folks that do not use Inline::C
sub pi_fork_exec ($$$$$$$) {
	my ($redir, $f, $cmd, $env, $rlim, $cd, $pgid) = @_;
	my $old = POSIX::SigSet->new();
	my $set = POSIX::SigSet->new();
	$set->fillset or die "fillset failed: $!";
	sigprocmask(SIG_SETMASK, $set, $old) or die "can't block signals: $!";
	my $syserr;
	pipe(my ($r, $w));
	my $pid = fork;
	unless (defined $pid) { # compat with Inline::C version
		$syserr = $!;
		$pid = -1;
	}
	if ($pid == 0) {
		close $r;
		$SIG{__DIE__} = sub {
			warn(@_);
			syswrite($w, my $num = $! + 0);
			_exit(1);
		};
		for my $child_fd (0..$#$redir) {
			my $parent_fd = $redir->[$child_fd];
			next if $parent_fd == $child_fd;
			dup2($parent_fd, $child_fd) or
				die "dup2($parent_fd, $child_fd): $!";
		}
		if ($pgid >= 0 && !defined(setpgid(0, $pgid))) {
			die "setpgid(0, $pgid): $!";
		}
		for (keys %SIG) {
			$SIG{$_} = 'DEFAULT' if substr($_, 0, 1) ne '_';
		}
		if ($cd ne '') {
			chdir $cd or die "chdir $cd: $!";
		}
		while (@$rlim) {
			my ($r, $soft, $hard) = splice(@$rlim, 0, 3);
			BSD::Resource::setrlimit($r, $soft, $hard) or
				die "setrlimit($r=[$soft,$hard]: $!)";
		}
		$old->delset(POSIX::SIGCHLD) or die "delset SIGCHLD: $!";
		sigprocmask(SIG_SETMASK, $old) or die "SETMASK: ~SIGCHLD: $!";
		$cmd->[0] = $f;
		if ($ENV{MOD_PERL}) {
			@$cmd = (which('env'), '-i', @$env, @$cmd);
		} else {
			%ENV = map { split(/=/, $_, 2) } @$env;
		}
		undef $r;
		exec { $f } @$cmd;
		die "exec @$cmd failed: $!";
	}
	close $w;
	sigprocmask(SIG_SETMASK, $old) or die "can't unblock signals: $!";
	if (my $cerrnum = do { local $/, <$r> }) {
		$pid = -1;
		$! = $cerrnum;
	} else {
		$! = $syserr;
	}
	$pid;
}

1;
