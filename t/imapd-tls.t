#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Socket qw(IPPROTO_TCP SOL_SOCKET);
use PublicInbox::TestCommon;
# IO::Poll is part of the standard library, but distros may split it off...
require_mods(qw(-imapd IO::Socket::SSL Mail::IMAPClient IO::Poll));
my $imap_client = 'Mail::IMAPClient';
$imap_client->can('starttls') or
	plan skip_all => 'Mail::IMAPClient does not support TLS';
my $can_compress = $imap_client->can('compress');
if ($can_compress) { # hope this gets fixed upstream, soon
	require PublicInbox::IMAPClient;
	$imap_client = 'PublicInbox::IMAPClient';
}

my $cert = 'certs/server-cert.pem';
my $key = 'certs/server-key.pem';
unless (-r $key && -r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run $^X ./create-certs.perl in certs/";
}
use_ok 'PublicInbox::TLS';
use_ok 'IO::Socket::SSL';
my $version = 1; # v2 needs newer git
require_git('2.6') if $version >= 2;
my ($tmpdir, $for_destroy) = tmpdir();
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $pi_config;
my $group = 'test-imapd-tls';
my $addr = $group . '@example.com';
my $starttls = tcp_server();
my $imaps = tcp_server();
my $ibx = create_inbox 'imapd-tls', version => $version,
			-primary_address => $addr, indexlevel => 'basic', sub {
	my ($im, $ibx) = @_;
	$im->add(eml_load('t/data/0001.patch')) or BAIL_OUT '->add';
	$pi_config = "$ibx->{inboxdir}/pi_config";
	open my $fh, '>', $pi_config or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT "print: $!";
[publicinbox "imapd-tls"]
	inboxdir = $ibx->{inboxdir}
	address = $addr
	indexlevel = basic
	newsgroup = $group
EOF
	close $fh or BAIL_OUT "close: $!\n";
};
$pi_config //= "$ibx->{inboxdir}/pi_config";

my $imaps_addr = tcp_host_port($imaps);
my $starttls_addr = tcp_host_port($starttls);
my $env = { PI_CONFIG => $pi_config };
my $td;

for my $args (
	[ "--cert=$cert", "--key=$key",
		"-limaps://$imaps_addr",
		"-limap://$starttls_addr" ],
) {
	for ($out, $err) {
		open my $fh, '>', $_ or BAIL_OUT "truncate: $!";
	}
	my $cmd = [ '-imapd', '-W0', @$args, "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, $env, { 3 => $starttls, 4 => $imaps });
	my %o = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	# start negotiating a slow TLS connection
	my $slow = tcp_connect($imaps, Blocking => 0);
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
	my %imaps_opt = (User => 'a', Password => 'b',
			Server => $imaps->sockhost,
			Port => $imaps->sockport);
	# IMAPS
	my $c = $imap_client->new(%imaps_opt, Ssl => [ %o ]);
	ok($c && $c->IsAuthenticated, 'authenticated');
	ok($c->select($group), 'SELECT works');
	ok(!(scalar $c->has_capability('STARTTLS')),
		'starttls not advertised with IMAPS');
	ok(!$c->starttls, "starttls fails");
	ok($c->has_capability('COMPRESS') ||
		$c->has_capability('COMPRESS=DEFLATE'),
		'compress advertised');
	ok($c->compress, 'compression enabled with IMAPS');
	ok(!$c->starttls, 'starttls still fails');
	ok($c->noop, 'noop succeeds');
	ok($c->logout, 'logout succeeds');

	# STARTTLS
	my %imap_opt = (Server => $starttls->sockhost,
			Port => $starttls->sockport);
	$c = $imap_client->new(%imap_opt);
	ok(scalar $c->has_capability('STARTTLS'),
		'starttls advertised');
	ok($c->Starttls([ %o ]), 'set starttls options');
	ok($c->starttls, '->starttls works');
	ok(!(scalar($c->has_capability('STARTTLS'))),
		'starttls not advertised');
	ok(!$c->starttls, '->starttls again fails');
	ok(!(scalar($c->has_capability('STARTTLS'))),
		'starttls still not advertised');
	ok($c->examine($group), 'EXAMINE works');
	ok($c->noop, 'NOOP works');
	ok($c->compress, 'compression enabled with IMAPS');
	ok($c->noop, 'NOOP works after compress');
	ok($c->logout, 'logout succeeds after compress');

	# STARTTLS with bad hostname
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.invalid';
	$c = $imap_client->new(%imap_opt);
	ok(scalar $c->has_capability('STARTTLS'), 'starttls advertised');
	ok($c->Starttls([ %o ]), 'set starttls options');
	ok(!$c->starttls, '->starttls fails with bad hostname');

	$c = $imap_client->new(%imap_opt);
	ok($c->noop, 'NOOP still works from plain IMAP');

	# IMAPS with bad hostname
	$c = $imap_client->new(%imaps_opt, Ssl => [ %o ]);
	is($c, undef, 'IMAPS fails with bad hostname');

	# make hostname valid
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.local';
	$c = $imap_client->new(%imaps_opt, Ssl => [ %o ]);
	ok($c, 'IMAPS succeeds again with valid hostname');

	# slow TLS connection did not block the other fast clients while
	# connecting, finish it off:
	until ($slow_done) {
		IO::Poll::_poll(-1, @poll);
		$slow_done = $slow->connect_SSL and last;
		@poll = (fileno($slow), PublicInbox::TLS::epollbit());
	}
	$slow->blocking(1);
	ok(sysread($slow, my $greet, 4096) > 0, 'slow got a greeting');
	like($greet, qr/\A\* OK \[CAPABILITY IMAP4rev1 /, 'got greeting');
	is(syswrite($slow, "1 LOGOUT\r\n"), 10, 'slow wrote LOGOUT');
	ok(sysread($slow, my $end, 4096) > 0, 'got end');
	is(sysread($slow, my $eof, 4096), 0, 'got EOF');

	test_lei(sub {
		lei_ok qw(ls-mail-source), "imap://$starttls_addr",
			\'STARTTLS not used by default';
		ok(!lei(qw(ls-mail-source -c imap.starttls=true),
			"imap://$starttls_addr"), 'STARTTLS verify fails');
	});

	SKIP: {
		skip 'TCP_DEFER_ACCEPT is Linux-only', 2 if $^O ne 'linux';
		my $var = eval { Socket::TCP_DEFER_ACCEPT() } // 9;
		defined(my $x = getsockopt($imaps, IPPROTO_TCP, $var)) or die;
		ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set on IMAPS');
		defined($x = getsockopt($starttls, IPPROTO_TCP, $var)) or die;
		is(unpack('i', $x), 0, 'TCP_DEFER_ACCEPT is 0 on plain IMAP');
	};
	SKIP: {
		skip 'SO_ACCEPTFILTER is FreeBSD-only', 2 if $^O ne 'freebsd';
		if (system('kldstat -m accf_data >/dev/null')) {
			skip 'accf_data not loaded? kldload accf_data', 2;
		}
		require PublicInbox::Daemon;
		my $var = PublicInbox::Daemon::SO_ACCEPTFILTER();
		my $x = getsockopt($imaps, SOL_SOCKET, $var);
		like($x, qr/\Adataready\0+\z/, 'got dataready accf for IMAPS');
		$x = getsockopt($starttls, IPPROTO_TCP, $var);
		is($x, undef, 'no BSD accept filter for plain IMAP');
	};

	$c = undef;
	$td->kill;
	$td->join;
	is($?, 0, 'no error in exited process');
	open my $fh, '<', $err or BAIL_OUT "open $err failed: $!";
	my $eout = do { local $/; <$fh> };
	unlike($eout, qr/wide/i, 'no Wide character warnings');
}

done_testing;
