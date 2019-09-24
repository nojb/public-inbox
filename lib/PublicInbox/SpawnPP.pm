# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Pure-Perl implementation of "spawn".  This can't take advantage
# of vfork, so no speedups under Linux for spawning from large processes.
package PublicInbox::SpawnPP;
use strict;
use warnings;
use POSIX qw(dup2 :signal_h);

# Pure Perl implementation for folks that do not use Inline::C
sub pi_fork_exec ($$$$$$) {
	my ($in, $out, $err, $f, $cmd, $env, $rlim) = @_;
	my $old = POSIX::SigSet->new();
	my $set = POSIX::SigSet->new();
	$set->fillset or die "fillset failed: $!";
	sigprocmask(SIG_SETMASK, $set, $old) or die "can't block signals: $!";
	my $syserr;
	my $pid = fork;
	unless (defined $pid) { # compat with Inline::C version
		$syserr = $!;
		$pid = -1;
	}
	if ($pid == 0) {
		while (@$rlim) {
			my ($r, $soft, $hard) = splice(@$rlim, 0, 3);
			BSD::Resource::setrlimit($r, $soft, $hard) or
			  warn "failed to set $r=[$soft,$hard]\n";
		}
		if ($in != 0) {
			dup2($in, 0) or die "dup2 failed for stdin: $!";
		}
		if ($out != 1) {
			dup2($out, 1) or die "dup2 failed for stdout: $!";
		}
		if ($err != 2) {
			dup2($err, 2) or die "dup2 failed for stderr: $!";
		}

		if ($ENV{MOD_PERL}) {
			exec which('env'), '-i', @$env, @$cmd;
			die "exec env -i ... $cmd->[0] failed: $!\n";
		} else {
			local %ENV = map { split(/=/, $_, 2) } @$env;
			my @cmd = @$cmd;
			$cmd[0] = $f;
			exec @cmd;
			die "exec $cmd->[0] failed: $!\n";
		}
	}
	sigprocmask(SIG_SETMASK, $old) or die "can't unblock signals: $!";
	$! = $syserr;
	$pid;
}

1;
