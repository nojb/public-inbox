# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(SOCK_STREAM IPPROTO_TCP SOL_SOCKET);
# IO::Poll is part of the standard library, but distros may split them off...
foreach my $mod (qw(IO::Socket::SSL IO::Poll)) {
	eval "require $mod";
	plan skip_all => "$mod missing for $0" if $@;
}
my $cert = 'certs/server-cert.pem';
my $key = 'certs/server-key.pem';
unless (-r $key && -r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run ./create-certs.perl in certs/";
}
use_ok 'PublicInbox::TLS';
use_ok 'IO::Socket::SSL';
require './t/common.perl';
my $psgi = "./t/httpd-corner.psgi";
my $tmpdir = tempdir('pi-httpd-https-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $httpd = 'blib/script/public-inbox-httpd';
my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Type => SOCK_STREAM,
	Listen => 1024,
);
my $https = IO::Socket::INET->new(%opts);
my ($pid, $tail_pid);
END {
	foreach ($pid, $tail_pid) {
		kill 'TERM', $_ if defined $_;
	}
};
my $https_addr = $https->sockhost . ':' . $https->sockport;
my %opt = ( Proto => 'tcp', PeerAddr => $https_addr, Type => SOCK_STREAM );

for my $args (
	[ "-lhttps://$https_addr/?key=$key,cert=$cert" ],
) {
	for ($out, $err) {
		open my $fh, '>', $_ or die "truncate: $!";
	}
	if (my $tail_cmd = $ENV{TAIL}) { # don't assume GNU tail
		$tail_pid = fork;
		if (defined $tail_pid && $tail_pid == 0) {
			exec(split(' ', $tail_cmd), $out, $err);
		}
	}
	my $cmd = [ $httpd, '-W0', @$args,
			"--stdout=$out", "--stderr=$err", $psgi ];
	$pid = spawn_listener(undef, $cmd, [ $https ]);
	my %o = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	# start negotiating a slow TLS connection
	my $slow = IO::Socket::INET->new(%opt, Blocking => 0);
	$slow = IO::Socket::SSL->start_SSL($slow, SSL_startHandshake => 0, %o);
	my @poll = (fileno($slow));
	my $slow_done = $slow->connect_SSL;
	if ($slow_done) {
		diag('W: connect_SSL early OK, slow client test invalid');
		push @poll, PublicInbox::Syscall::EPOLLOUT();
	} else {
		push @poll, PublicInbox::TLS::epollbit();
	}

	# normal HTTPS
	my $c = IO::Socket::INET->new(%opt);
	IO::Socket::SSL->start_SSL($c, %o);
	ok($c->print("GET /empty HTTP/1.1\r\n\r\nHost: example.com\r\n\r\n"),
		'wrote HTTP request');
	my $buf = '';
	sysread($c, $buf, 2007, length($buf)) until $buf =~ /\r\n\r\n/;
	like($buf, qr!\AHTTP/1\.1 200!, 'read HTTP response');

	# HTTPS with bad hostname
	$c = IO::Socket::INET->new(%opt);
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.fail';
	$c = IO::Socket::SSL->start_SSL($c, %o);
	is($c, undef, 'HTTPS fails with bad hostname');

	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.local';
	$c = IO::Socket::INET->new(%opt);
	IO::Socket::SSL->start_SSL($c, %o);
	ok($c, 'HTTPS succeeds again with valid hostname');

	# slow TLS connection did not block the other fast clients while
	# connecting, finish it off:
	until ($slow_done) {
		IO::Poll::_poll(-1, @poll);
		$slow_done = $slow->connect_SSL and last;
		@poll = (fileno($slow), PublicInbox::TLS::epollbit());
	}
	$slow->blocking(1);
	ok($slow->print("GET /empty HTTP/1.1\r\n\r\nHost: example.com\r\n\r\n"),
		'wrote HTTP request from slow');
	$buf = '';
	sysread($slow, $buf, 666, length($buf)) until $buf =~ /\r\n\r\n/;
	like($buf, qr!\AHTTP/1\.1 200!, 'read HTTP response from slow');
	$slow = undef;

	SKIP: {
		skip 'TCP_DEFER_ACCEPT is Linux-only', 2 if $^O ne 'linux';
		my $var = Socket::TCP_DEFER_ACCEPT();
		defined(my $x = getsockopt($https, IPPROTO_TCP, $var)) or die;
		ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set on https');
	};
	SKIP: {
		skip 'SO_ACCEPTFILTER is FreeBSD-only', 2 if $^O ne 'freebsd';
		if (system('kldstat -m accf_data >/dev/null')) {
			skip 'accf_data not loaded? kldload accf_data', 2;
		}
		require PublicInbox::Daemon;
		my $var = PublicInbox::Daemon::SO_ACCEPTFILTER();
		my $x = getsockopt($https, SOL_SOCKET, $var);
		like($x, qr/\Adataready\0+\z/, 'got dataready accf for https');
	};

	$c = undef;
	kill('TERM', $pid);
	is($pid, waitpid($pid, 0), 'httpd exited successfully');
	is($?, 0, 'no error in exited process');
	$pid = undef;
	if (defined $tail_pid) {
		kill 'TERM', $tail_pid;
		waitpid($tail_pid, 0);
		$tail_pid = undef;
	}
}
done_testing();
1;
