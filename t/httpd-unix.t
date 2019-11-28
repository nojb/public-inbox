# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Tests for binding Unix domain sockets
use strict;
use warnings;
use Test::More;
require './t/common.perl';
use Errno qw(EADDRINUSE);

foreach my $mod (qw(Plack::Util Plack::Builder HTTP::Date HTTP::Status)) {
	eval "require $mod";
	plan skip_all => "$mod missing for httpd-unix.t" if $@;
}

use IO::Socket::UNIX;
my ($tmpdir, $for_destroy) = tmpdir();
my $unix = "$tmpdir/unix.sock";
my $psgi = './t/httpd-corner.psgi';
my $out = "$tmpdir/out.log";
my $err = "$tmpdir/err.log";
my $td;

my $spawn_httpd = sub {
	my (@args) = @_;
	push @args, '-W0';
	my $cmd = [ '-httpd', @args, "--stdout=$out", "--stderr=$err", $psgi ];
	$td = start_script($cmd);
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
my %o = (Peer => $unix, Type => SOCK_STREAM);
for (1..1000) {
	last if -S $unix && IO::Socket::UNIX->new(%o);
	select undef, undef, undef, 0.02
}

ok(-S $unix, 'UNIX socket was bound by -httpd');
sub check_sock ($) {
	my ($unix) = @_;
	my $sock = IO::Socket::UNIX->new(Peer => $unix, Type => SOCK_STREAM);
	warn "E: $! connecting to $unix\n" unless defined $sock;
	ok($sock, 'client UNIX socket connected');
	ok($sock->write("GET /host-port HTTP/1.0\r\n\r\n"),
		'wrote req to server');
	ok($sock->read(my $buf, 4096), 'read response');
	like($buf, qr!\r\n\r\n127\.0\.0\.1:0\z!,
		'set REMOTE_ADDR and REMOTE_PORT for Unix socket');
}

check_sock($unix);

{ # do not clobber existing socket
	my %err = ( 'linux' => EADDRINUSE, 'freebsd' => EADDRINUSE );
	open my $out, '>>', "$tmpdir/1" or die "redirect failed: $!";
	open my $err, '>>', "$tmpdir/2" or die "redirect failed: $!";
	my $cmd = ['-httpd', '-l', $unix, '-W0', $psgi];
	my $ftd = start_script($cmd, undef, { 1 => $out, 2 => $err });
	$ftd->join;
	isnt($?, 0, 'httpd failure set $?');
	SKIP: {
		my $ec = $err{$^O} or
			skip("not sure if $^O fails with EADDRINUSE", 1);
		is($? >> 8, $ec, 'httpd failed with EADDRINUSE');
	};
	open my $fh, "$tmpdir/2" or die "failed to open $tmpdir/2: $!";
	local $/;
	my $e = <$fh>;
	like($e, qr/no listeners bound/i, 'got error message');
	is(-s "$tmpdir/1", 0, 'stdout was empty');
}

{
	is($td->kill, 1, 'terminate existing process');
	$td->join;
	is($?, 0, 'existing httpd exited successfully');
	ok(-S $unix, 'unix socket still exists');
}

SKIP: {
	eval 'require Net::Server::Daemonize';
	skip('Net::Server missing for pid-file/daemonization test', 10) if $@;

	# wait for daemonization
	$spawn_httpd->("-l$unix", '-D', '-P', "$tmpdir/pid");
	$td->join;
	is($?, 0, 'daemonized process OK');
	check_sock($unix);

	ok(-f "$tmpdir/pid", 'pid file written');
	open my $fh, '<', "$tmpdir/pid" or die "open failed: $!";
	local $/ = "\n";
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
