#!perl -w
# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use Socket qw(IPPROTO_TCP SOL_SOCKET);
require_mods(qw(Plack::Util Plack::Builder HTTP::Date HTTP::Status));

# FIXME: too much setup
my ($tmpdir, $for_destroy) = tmpdir();
my $home = "$tmpdir/pi-home";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $inboxdir = "$tmpdir/i.git";
my $group = 'test-httpd';
my $addr = $group . '@example.com';
my $sock = tcp_server();
my $td;
{
	create_inbox 'test', tmpdir => $inboxdir, sub {
		my ($im, $ibx) = @_;
		$im->add(PublicInbox::Eml->new(<<EOF)) or BAIL_OUT;
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 06:06:06 +0000

nntp
EOF
	};
	my $i2 = create_inbox 'test-2', sub {
		my ($im, $ibx) = @_;
		$im->add(eml_load('t/plack-qp.eml')) or xbail '->add';
	};
	local $ENV{HOME} = $home;
	my $cmd = [ '-init', $group, $inboxdir, 'http://example.com/', $addr ];
	ok(run_script($cmd), 'init ran properly');
	$cmd = [ '-httpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, undef, { 3 => $sock });
	my $http_pfx = 'http://'.tcp_host_port($sock);
	{
		my $bad = tcp_connect($sock);
		print $bad "GETT / HTTP/1.0\r\n\r\n" or die;
		like(<$bad>, qr!\AHTTP/1\.[01] 405\b!, 'got 405 on bad req');
	}
	my $conn = tcp_connect($sock);
	ok($conn->write("GET / HTTP/1.0\r\n\r\n"), 'wrote data to socket');
	{
		my $buf;
		ok($conn->read($buf, 4096), 'read some bytes');
		like($buf, qr!\AHTTP/1\.[01] 404\b!, 'got 404 response');
		is($conn->read($buf, 1), 0, "EOF");
	}

	is(xsys(qw(git clone -q --mirror),
			"$http_pfx/$group", "$tmpdir/clone.git"),
		0, 'smart clone successful');

	# ensure dumb cloning works, too:
	is(xsys('git', "--git-dir=$inboxdir",
		qw(config http.uploadpack false)),
		0, 'disable http.uploadpack');
	is(xsys(qw(git clone -q --mirror),
			"$http_pfx/$group", "$tmpdir/dumb.git"),
		0, 'clone successful');

	# test config reload
	my $cfg = "$home/.public-inbox/config";
	open my $fh, '>>', $cfg or xbail "open: $!";
	print $fh <<EOM or xbail "print $!";
[publicinbox "test-2"]
	inboxdir = $i2->{inboxdir}
	address = test-2\@example.com
	url = https://example.com/test-2
EOM
	close $fh or xbail "close $!";
	$td->kill('HUP') or BAIL_OUT "failed to kill -httpd: $!";
	tick; # wait for HUP to take effect
	my $buf = do {
		my $c2 = tcp_connect($sock);
		$c2->write("GET /test-2/qp\@example.com/raw HTTP/1.0\r\n\r\n")
					or xbail "c2 write: $!";
		local $/;
		<$c2>
	};
	like($buf, qr!\AHTTP/1\.0 200\b!s, 'got 200 after reload for test-2');

	ok($td->kill, 'killed httpd');
	$td->join;

	is(xsys('git', "--git-dir=$tmpdir/clone.git",
		  qw(fsck --no-verbose)), 0,
		'fsck on cloned directory successful');
}

SKIP: {
	skip 'TCP_DEFER_ACCEPT is Linux-only', 1 if $^O ne 'linux';
	my $var = eval { Socket::TCP_DEFER_ACCEPT() } // 9;
	defined(my $x = getsockopt($sock, IPPROTO_TCP, $var)) or die;
	ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set');
};
SKIP: {
	skip 'SO_ACCEPTFILTER is FreeBSD-only', 1 if $^O ne 'freebsd';
	if (system('kldstat -m accf_http >/dev/null') != 0) {
		skip 'accf_http not loaded: kldload accf_http', 1;
	}
	require PublicInbox::Daemon;
	ok(defined($PublicInbox::Daemon::SO_ACCEPTFILTER),
		'SO_ACCEPTFILTER defined');
	my $x = getsockopt($sock, SOL_SOCKET,
			$PublicInbox::Daemon::SO_ACCEPTFILTER);
	like($x, qr/\Ahttpready\0+\z/, 'got httpready accf for HTTP');
};

done_testing;
