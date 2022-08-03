#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
use Socket qw(SOCK_STREAM IPPROTO_TCP SOL_SOCKET);
use PublicInbox::TestCommon;
use File::Copy qw(cp);
# IO::Poll is part of the standard library, but distros may split them off...
require_mods(qw(IO::Socket::SSL IO::Poll Plack::Util));
my @certs = qw(certs/server-cert.pem certs/server-key.pem
	certs/server2-cert.pem certs/server2-key.pem);
if (scalar(grep { -r $_ } @certs) != scalar(@certs)) {
	plan skip_all =>
		"certs/ missing for $0, run $^X ./create-certs.perl in certs/";
}
use_ok 'PublicInbox::TLS';
use_ok 'IO::Socket::SSL';
my $psgi = "./t/httpd-corner.psgi";
my ($tmpdir, $for_destroy) = tmpdir();
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $https = tcp_server();
my $td;
my $https_addr = tcp_host_port($https);
my $cert = "$tmpdir/cert.pem";
my $key = "$tmpdir/key.pem";
cp('certs/server-cert.pem', $cert) or xbail $!;
cp('certs/server-key.pem', $key) or xbail $!;

my $check_url_scheme = sub {
	my ($s, $line) = @_;
	$s->print("GET /url_scheme HTTP/1.1\r\n\r\nHost: example.com\r\n\r\n")
		or xbail "failed to write HTTP request: $! (line $line)";
	my $buf = '';
	sysread($s, $buf, 2007, length($buf)) until $buf =~ /\r\n\r\nhttps?/;
	like($buf, qr!\AHTTP/1\.1 200!, "read HTTPS response (line $line)");
	like($buf, qr!\r\nhttps\z!, "psgi.url_scheme is 'https' (line $line)");
};

for my $args (
	[ "-lhttps://$https_addr/?key=$key,cert=$cert" ],
) {
	for ($out, $err) {
		open my $fh, '>', $_ or die "truncate: $!";
	}
	my $cmd = [ '-httpd', '-W0', @$args,
			"--stdout=$out", "--stderr=$err", $psgi ];
	$td = start_script($cmd, undef, { 3 => $https });
	my %o = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	# start negotiating a slow TLS connection
	my $slow = tcp_connect($https, Blocking => 0);
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
	my $c = tcp_connect($https);
	IO::Socket::SSL->start_SSL($c, %o);
	$check_url_scheme->($c, __LINE__);

	# HTTPS with bad hostname
	$c = tcp_connect($https);
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.fail';
	$c = IO::Socket::SSL->start_SSL($c, %o);
	is($c, undef, 'HTTPS fails with bad hostname');

	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.local';
	$c = tcp_connect($https);
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
	my $buf = '';
	sysread($slow, $buf, 666, length($buf)) until $buf =~ /\r\n\r\n/;
	like($buf, qr!\AHTTP/1\.1 200!, 'read HTTP response from slow');
	$slow = undef;

	SKIP: {
		skip 'TCP_DEFER_ACCEPT is Linux-only', 2 if $^O ne 'linux';
		my $var = eval { Socket::TCP_DEFER_ACCEPT() } // 9;
		defined(my $x = getsockopt($https, IPPROTO_TCP, $var)) or die;
		ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set on https');
	};
	SKIP: {
		skip 'SO_ACCEPTFILTER is FreeBSD-only', 2 if $^O ne 'freebsd';
		if (system('kldstat -m accf_data >/dev/null')) {
			skip 'accf_data not loaded? kldload accf_data', 2;
		}
		require PublicInbox::Daemon;
		ok(defined($PublicInbox::Daemon::SO_ACCEPTFILTER),
			'SO_ACCEPTFILTER defined');
		my $x = getsockopt($https, SOL_SOCKET,
				$PublicInbox::Daemon::SO_ACCEPTFILTER);
		like($x, qr/\Adataready\0+\z/, 'got dataready accf for https');
	};

	# switch cert and key:
	cp('certs/server2-cert.pem', $cert) or xbail $!;
	cp('certs/server2-key.pem', $key) or xbail $!;
	$td->kill('HUP') or xbail "kill: $!";
	tick(); # wait for SIGHUP to take effect (hopefully :x)

	my $d = tcp_connect($https);
	$d = IO::Socket::SSL->start_SSL($d, %o);
	is($d, undef, 'HTTPS fails with bad hostname after new cert on HUP');

	$d = tcp_connect($https);
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server2.local';
	is(IO::Socket::SSL->start_SSL($d, %o), $d,
		'new hostname to match cert works after HUP');
	$check_url_scheme->($d, __LINE__);

	# existing connection w/ old cert still works:
	$check_url_scheme->($c, __LINE__);

	undef $c;
	undef $d;
	$td->kill;
	$td->join;
	is($?, 0, 'no error in exited process');
}
done_testing();
1;
