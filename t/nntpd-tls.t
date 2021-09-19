#!perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use Socket qw(SOCK_STREAM IPPROTO_TCP SOL_SOCKET);
# IO::Poll and Net::NNTP are part of the standard library, but
# distros may split them off...
require_mods(qw(DBD::SQLite IO::Socket::SSL Net::NNTP IO::Poll));
Net::NNTP->can('starttls') or
	plan skip_all => 'Net::NNTP does not support TLS';

my $cert = 'certs/server-cert.pem';
my $key = 'certs/server-key.pem';
unless (-r $key && -r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run $^X ./create-certs.perl in certs/";
}

use_ok 'PublicInbox::TLS';
use_ok 'IO::Socket::SSL';
our $need_zlib;
eval { require Compress::Raw::Zlib } or
	$need_zlib = 'Compress::Raw::Zlib missing';
my $version = 2; # v2 needs newer git
require_git('2.6') if $version >= 2;
my ($tmpdir, $for_destroy) = tmpdir();
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $group = 'test-nntpd-tls';
my $addr = $group . '@example.com';
my $starttls = tcp_server();
my $nntps = tcp_server();
my $pi_config;
my $ibx = create_inbox "v$version", version => $version, indexlevel => 'basic',
			sub {
	my ($im, $ibx) = @_;
	$pi_config = "$ibx->{inboxdir}/pi_config";
	open my $fh, '>', $pi_config or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT;
[publicinbox "nntpd-tls"]
	inboxdir = $ibx->{inboxdir}
	address = $addr
	indexlevel = basic
	newsgroup = $group
EOF
	close $fh or BAIL_OUT "close: $!";
	$im->add(eml_load 't/data/0001.patch') or BAIL_OUT;
};
$pi_config //= "$ibx->{inboxdir}/pi_config";
undef $ibx;
my $nntps_addr = tcp_host_port($nntps);
my $starttls_addr = tcp_host_port($starttls);
my $env = { PI_CONFIG => $pi_config };
my $td;

for my $args (
	[ "--cert=$cert", "--key=$key",
		"-lnntps://$nntps_addr",
		"-lnntp://$starttls_addr" ],
) {
	for ($out, $err) {
		open my $fh, '>', $_ or die "truncate: $!";
	}
	my $cmd = [ '-nntpd', '-W0', @$args, "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, $env, { 3 => $starttls, 4 => $nntps });
	my %o = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	my $expect = { $group => [qw(1 1 n)] };

	# start negotiating a slow TLS connection
	my $slow = tcp_connect($nntps, Blocking => 0);
	$slow = IO::Socket::SSL->start_SSL($slow, SSL_startHandshake => 0, %o);
	my $slow_done = $slow->connect_SSL;
	my @poll;
	if ($slow_done) {
		diag('W: connect_SSL early OK, slow client test invalid');
		use PublicInbox::Syscall qw(EPOLLIN EPOLLOUT);
		@poll = (fileno($slow), EPOLLIN | EPOLLOUT);
	} else {
		@poll = (fileno($slow), PublicInbox::TLS::epollbit());
	}
	# we should call connect_SSL much later...

	# NNTPS
	my $c = Net::NNTP->new($nntps_addr, %o, SSL => 1);
	my $list = $c->list;
	is_deeply($list, $expect, 'NNTPS LIST works');
	unlike(get_capa($c), qr/\bSTARTTLS\r\n/,
		'STARTTLS not advertised for NNTPS');
	is($c->command('QUIT')->response(), Net::Cmd::CMD_OK(), 'QUIT works');
	is(0, sysread($c, my $buf, 1), 'got EOF after QUIT');

	# STARTTLS
	$c = Net::NNTP->new($starttls_addr, %o);
	$list = $c->list;
	is_deeply($list, $expect, 'plain LIST works');
	ok($c->starttls, 'STARTTLS succeeds');
	is($c->code, 382, 'got 382 for STARTTLS');
	$list = $c->list;
	is_deeply($list, $expect, 'LIST works after STARTTLS');
	unlike(get_capa($c), qr/\bSTARTTLS\r\n/,
		'STARTTLS not advertised after STARTTLS');

	# Net::NNTP won't let us do dumb things, but we need to test
	# dumb things, so use Net::Cmd directly:
	my $n = $c->command('STARTTLS')->response();
	is($n, Net::Cmd::CMD_ERROR(), 'error attempting STARTTLS again');
	is($c->code, 502, '502 according to RFC 4642 sec#2.2.1');

	# STARTTLS with bad hostname
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.invalid';
	$c = Net::NNTP->new($starttls_addr, %o);
	like(get_capa($c), qr/\bSTARTTLS\r\n/, 'STARTTLS advertised');
	$list = $c->list;
	is_deeply($list, $expect, 'plain LIST works again');
	ok(!$c->starttls, 'STARTTLS fails with bad hostname');
	$c = Net::NNTP->new($starttls_addr, %o);
	$list = $c->list;
	is_deeply($list, $expect, 'not broken after bad negotiation');

	# NNTPS with bad hostname
	$c = Net::NNTP->new($nntps_addr, %o, SSL => 1);
	is($c, undef, 'NNTPS fails with bad hostname');
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.local';
	$c = Net::NNTP->new($nntps_addr, %o, SSL => 1);
	ok($c, 'NNTPS succeeds again with valid hostname');

	# slow TLS connection did not block the other fast clients while
	# connecting, finish it off:
	until ($slow_done) {
		IO::Poll::_poll(-1, @poll);
		$slow_done = $slow->connect_SSL and last;
		@poll = (fileno($slow), PublicInbox::TLS::epollbit());
	}
	$slow->blocking(1);
	ok(sysread($slow, my $greet, 4096) > 0, 'slow got greeting');
	like($greet, qr/\A201 /, 'got expected greeting');
	is(syswrite($slow, "QUIT\r\n"), 6, 'slow wrote QUIT');
	ok(sysread($slow, my $end, 4096) > 0, 'got EOF');
	is(sysread($slow, my $eof, 4096), 0, 'got EOF');
	$slow = undef;

	test_lei(sub {
		lei_ok qw(ls-mail-source), "nntp://$starttls_addr",
			\'STARTTLS not used by default';
		ok(!lei(qw(ls-mail-source -c nntp.starttls=true),
			"nntp://$starttls_addr"), 'STARTTLS verify fails');
		diag $lei_err;
	});

	SKIP: {
		skip 'TCP_DEFER_ACCEPT is Linux-only', 2 if $^O ne 'linux';
		my $var = eval { Socket::TCP_DEFER_ACCEPT() } // 9;
		defined(my $x = getsockopt($nntps, IPPROTO_TCP, $var)) or die;
		ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set on NNTPS');
		defined($x = getsockopt($starttls, IPPROTO_TCP, $var)) or die;
		is(unpack('i', $x), 0, 'TCP_DEFER_ACCEPT is 0 on plain NNTP');
	};
	SKIP: {
		skip 'SO_ACCEPTFILTER is FreeBSD-only', 2 if $^O ne 'freebsd';
		if (system('kldstat -m accf_data >/dev/null')) {
			skip 'accf_data not loaded? kldload accf_data', 2;
		}
		require PublicInbox::Daemon;
		my $var = PublicInbox::Daemon::SO_ACCEPTFILTER();
		my $x = getsockopt($nntps, SOL_SOCKET, $var);
		like($x, qr/\Adataready\0+\z/, 'got dataready accf for NNTPS');
		$x = getsockopt($starttls, IPPROTO_TCP, $var);
		is($x, undef, 'no BSD accept filter for plain NNTP');
	};

	$c = undef;
	$td->kill;
	$td->join;
	is($?, 0, 'no error in exited process');
	my $eout = eval {
		open my $fh, '<', $err or die "open $err failed: $!";
		local $/;
		<$fh>;
	};
	unlike($eout, qr/wide/i, 'no Wide character warnings');
}
done_testing();

sub get_capa {
	my ($sock) = @_;
	syswrite($sock, "CAPABILITIES\r\n");
	my $capa = '';
	do {
		my $r = sysread($sock, $capa, 8192, length($capa));
		die "unexpected: $!" unless defined($r);
		die 'unexpected EOF' if $r == 0;
	} until $capa =~ /\.\r\n\z/;

	my $deflate_capa = qr/\r\nCOMPRESS DEFLATE\r\n/;
	if ($need_zlib) {
		unlike($capa, $deflate_capa,
			'COMPRESS DEFLATE NOT advertised '.$need_zlib);
	} else {
		like($capa, $deflate_capa, 'COMPRESS DEFLATE advertised');
	}
	$capa;
}

1;
