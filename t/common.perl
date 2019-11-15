# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD :seek);
use POSIX qw(dup2);
use strict;
use warnings;
use IO::Socket::INET;

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

sub tcp_connect {
	my ($dest, %opt) = @_;
	my $s = IO::Socket::INET->new(
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		PeerAddr => $dest->sockhost . ':' . $dest->sockport,
		%opt,
	);
	$s->autoflush(1);
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

my %cached_scripts;
sub key2script ($) {
	my ($key) = @_;
	return $key if $key =~ m!\A/!;
	# n.b. we may have scripts which don't start with "public-inbox" in
	# the future:
	$key =~ s/\A([-\.])/public-inbox$1/;
	'blib/script/'.$key;
}

sub _prepare_redirects ($) {
	my ($fhref) = @_;
	my @x = ([ \*STDIN, '<&' ], [ \*STDOUT, '>&' ], [ \*STDERR, '>&' ]);
	for (my $fd = 0; $fd <= $#x; $fd++) {
		my $fh = $fhref->[$fd] or next;
		my ($oldfh, $mode) = @{$x[$fd]};
		open $oldfh, $mode, $fh or die "$$oldfh $mode redirect: $!";
	}
}

# $opt->{run_mode} (or $ENV{TEST_RUN_MODE}) allows chosing between
# three ways to spawn our own short-lived Perl scripts for testing:
#
# 0 - (fork|vfork) + execve, the most realistic but slowest
# 1 - preloading and running in a forked subprocess (fast)
# 2 - preloading and running in current process (slightly faster than 1)
#
# 2 is not compatible with scripts which use "exit" (which we'll try to
# avoid in the future).
# The default is 2.
our $run_script_exit_code;
sub RUN_SCRIPT_EXIT () { "RUN_SCRIPT_EXIT\n" };
sub run_script_exit (;$) {
	$run_script_exit_code = $_[0] // 0;
	die RUN_SCRIPT_EXIT;
}

sub run_script ($;$$) {
	my ($cmd, $env, $opt) = @_;
	my ($key, @argv) = @$cmd;
	my $run_mode = $ENV{TEST_RUN_MODE} // $opt->{run_mode} // 1;
	my $sub = $run_mode == 0 ? undef : ($cached_scripts{$key} //= do {
		my $f = key2script($key);
		open my $fh, '<', $f or die "open $f: $!";
		my $str = do { local $/; <$fh> };
		my ($fc, $rest) = ($key =~ m/([a-z])([a-z0-9]+)\z/);
		$fc = uc($fc);
		my $pkg = "PublicInbox::TestScript::$fc$rest";
		eval <<EOF;
package $pkg;
use strict;
use subs qw(exit);

*exit = *::run_script_exit;
sub main {
$str
	0;
}
1;
EOF
		$pkg->can('main');
	}); # do

	my $fhref = [];
	my $spawn_opt = {};
	for my $fd (0..2) {
		my $redir = $opt->{$fd};
		next unless ref($redir);
		open my $fh, '+>', undef or die "open: $!";
		$fhref->[$fd] = $fh;
		$spawn_opt->{$fd} = fileno($fh);
		next if $fd > 0;
		$fh->autoflush(1);
		print $fh $$redir or die "print: $!";
		seek($fh, 0, SEEK_SET) or die "seek: $!";
	}
	if ($run_mode == 0) {
		# spawn an independent new process, like real-world use cases:
		require PublicInbox::Spawn;
		my $cmd = [ key2script($key), @argv ];
		my $pid = PublicInbox::Spawn::spawn($cmd, $env, $spawn_opt);
		defined($pid) or die "spawn: $!";
		if (defined $pid) {
			my $r = waitpid($pid, 0);
			defined($r) or die "waitpid: $!";
			$r == $pid or die "waitpid: expected $pid, got $r";
		}
	} else { # localize and run everything in the same process:
		local *STDIN = *STDIN;
		local *STDOUT = *STDOUT;
		local *STDERR = *STDERR;
		local %ENV = $env ? (%ENV, %$env) : %ENV;
		local %SIG = %SIG;
		_prepare_redirects($fhref);
		local @ARGV = @argv;
		$run_script_exit_code = undef;
		my $exit_code = eval { $sub->(@argv) };
		if ($@ eq RUN_SCRIPT_EXIT) {
			$@ = '';
			$exit_code = $run_script_exit_code;
			$? = ($exit_code << 8);
		} elsif (defined($exit_code)) {
			$? = ($exit_code << 8);
		} elsif ($@) { # mimic die() behavior when uncaught
			warn "E: eval-ed $key: $@\n";
			$? = ($! << 8) if $!;
			$? = (255 << 8) if $? == 0;
		} else {
			die "BUG: eval-ed $key: no exit code or \$@\n";
		}
	}

	# slurp the redirects back into user-supplied strings
	for my $fd (1..2) {
		my $fh = $fhref->[$fd] or next;
		seek($fh, 0, SEEK_SET) or die "seek: $!";
		my $redir = $opt->{$fd};
		local $/;
		$$redir = <$fh>;
	}
	$? == 0;
}

1;
