# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use POSIX qw(dup2);
use strict;
use warnings;

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

sub tcp_server () {
	IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		Listen => 1024,
		Blocking => 0,
	)
}

sub unix_server ($) {
	my $s = IO::Socket::UNIX->new(
		Listen => 1024,
		Type => Socket::SOCK_STREAM(),
		Local => $_[0],
	);
	$s->blocking(0);
	$s;
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

sub require_git ($;$) {
	my ($req, $maybe) = @_;
	my ($req_maj, $req_min) = split(/\./, $req);
	my ($cur_maj, $cur_min) = (`git --version` =~ /version (\d+)\.(\d+)/);

	my $req_int = ($req_maj << 24) | ($req_min << 16);
	my $cur_int = ($cur_maj << 24) | ($cur_min << 16);
	if ($cur_int < $req_int) {
		return 0 if $maybe;
		plan skip_all => "git $req+ required, have $cur_maj.$cur_min";
	}
	1;
}

1;
