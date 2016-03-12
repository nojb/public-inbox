# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Tests for binding Unix domain sockets
use strict;
use warnings;
use Test::More;

foreach my $mod (qw(Plack::Util Plack::Request Plack::Builder Danga::Socket
			HTTP::Date HTTP::Status)) {
	eval "require $mod";
	plan skip_all => "$mod missing for httpd-unix.t" if $@;
}

use File::Temp qw/tempdir/;
use IO::Socket::UNIX;
use Cwd qw/getcwd/;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD :seek);
my $tmpdir = tempdir('httpd-unix-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $unix = "$tmpdir/unix.sock";
my $httpd = 'blib/script/public-inbox-httpd';
my $psgi = getcwd() . '/t/httpd-corner.psgi';
my $out = "$tmpdir/out.log";
my $err = "$tmpdir/err.log";

my $pid;
END { kill 'TERM', $pid if defined $pid };

my $spawn_httpd = sub {
	my (@args) = @_;
	$pid = fork;
	if ($pid == 0) {
		exec $httpd, @args, "--stdout=$out", "--stderr=$err", $psgi;
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked httpd process successfully');
};

{
	require PublicInbox::Daemon;
	my $l = "$tmpdir/named.sock";
	my $s = IO::Socket::UNIX->new(Listen => 5, Local => $l,
					Type => SOCK_STREAM);
	is(PublicInbox::Daemon::sockname($s), $l, 'sockname works for UNIX');
}

ok(!-S $unix, 'UNIX socket does not exist, yet');
$spawn_httpd->("-l$unix");
for (1..1000) {
	last if -S $unix;
	select undef, undef, undef, 0.02
}

ok(-S $unix, 'UNIX socket was bound by -httpd');
sub check_sock ($) {
	my ($unix) = @_;
	my $sock = IO::Socket::UNIX->new(Peer => $unix, Type => SOCK_STREAM);
	ok($sock, 'client UNIX socket connected');
	ok($sock->write("GET /host-port HTTP/1.0\r\n\r\n"),
		'wrote req to server');
	ok($sock->read(my $buf, 4096), 'read response');
	like($buf, qr!\r\n\r\n127\.0\.0\.1:0\z!,
		'set REMOTE_ADDR and REMOTE_PORT for Unix socket');
}

check_sock($unix);

{ # do not clobber existing socket
	my $fpid = fork;
	if ($fpid == 0) {
		open STDOUT, '>>', "$tmpdir/1" or die "redirect failed: $!";
		open STDERR, '>>', "$tmpdir/2" or die "redirect failed: $!";
		exec $httpd, '-l', $unix, '-W0', $psgi;
		die "FAIL: $!\n";
	}
	is($fpid, waitpid($fpid, 0), 'second httpd exits');
	isnt($?, 0, 'httpd failed with failure to bind');
	open my $fh, "$tmpdir/2" or die "failed to open $tmpdir/2: $!";
	local $/;
	my $e = <$fh>;
	like($e, qr/no listeners bound/i, 'got error message');
	is(-s "$tmpdir/1", 0, 'stdout was empty');
}

{
	my $kpid = $pid;
	$pid = undef;
	is(kill('TERM', $kpid), 1, 'terminate existing process');
	is(waitpid($kpid, 0), $kpid, 'existing httpd terminated');
	is($?, 0, 'existing httpd exited successfully');
	ok(-S $unix, 'unix socket still exists');
}

SKIP: {
	eval 'require Net::Server::Daemonize';
	skip('Net::Server missing for pid-file/daemonization test', 10) if $@;

	# wait for daemonization
	$spawn_httpd->("-l$unix", '-D', '-P', "$tmpdir/pid");
	my $kpid = $pid;
	$pid = undef;
	is(waitpid($kpid, 0), $kpid, 'existing httpd terminated');
	check_sock($unix);

	ok(-f "$tmpdir/pid", 'pid file written');
	open my $fh, '<', "$tmpdir/pid" or die "open failed: $!";
	my $rpid = <$fh>;
	chomp $rpid;
	like($rpid, qr/\A\d+\z/s, 'pid file looks like a pid');
	is(kill('TERM', $rpid), 1, 'signalled daemonized process');
	for (1..100) {
		kill(0, $rpid) or last;
		select undef, undef, undef, 0.02;
	}
	is(kill(0, $rpid), 0, 'daemonized process exited')
}

done_testing();
