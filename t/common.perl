# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use POSIX qw(dup2);

sub stream_to_string {
	my ($res) = @_;
	my $body = $res->[2];
	my $str = '';
	while (defined(my $chunk = $body->getline)) {
		$str .= $chunk;
	}
	$body->close;
	$str;
}

sub spawn_listener {
	my ($env, $cmd, $socks) = @_;
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		# pretend to be systemd (cf. sd_listen_fds(3))
		my $fd = 3; # 3 == SD_LISTEN_FDS_START
		foreach my $s (@$socks) {
			my $fl = fcntl($s, F_GETFD, 0);
			if (($fl & FD_CLOEXEC) != FD_CLOEXEC) {
				warn "got FD:".fileno($s)." w/o CLOEXEC\n";
			}
			fcntl($s, F_SETFD, $fl &= ~FD_CLOEXEC);
			dup2(fileno($s), $fd++) or die "dup2 failed: $!\n";
		}
		$ENV{LISTEN_PID} = $$;
		$ENV{LISTEN_FDS} = scalar @$socks;
		%ENV = (%ENV, %$env) if $env;
		exec @$cmd;
		die "FAIL: ",join(' ', @$cmd), ": $!\n";
	}
	$pid;
}

1;
