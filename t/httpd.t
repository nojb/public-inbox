# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use Socket qw(IPPROTO_TCP SOL_SOCKET);
require_mods(qw(Plack::Util Plack::Builder HTTP::Date HTTP::Status));

# FIXME: too much setup
my ($tmpdir, $for_destroy) = tmpdir();
my $home = "$tmpdir/pi-home";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $maindir = "$tmpdir/main.git";
my $group = 'test-httpd';
my $addr = $group . '@example.com';
my $cfgpfx = "publicinbox.$group";
my $sock = tcp_server();
my $td;
use_ok 'PublicInbox::Git';
use_ok 'PublicInbox::Import';
{
	local $ENV{HOME} = $home;
	my $cmd = [ '-init', $group, $maindir, 'http://example.com/', $addr ];
	ok(run_script($cmd), 'init ran properly');

	# ensure successful message delivery
	{
		my $mime = PublicInbox::Eml->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 06:06:06 +0000

nntp
EOF

		my $git = PublicInbox::Git->new($maindir);
		my $im = PublicInbox::Import->new($git, 'test', $addr);
		$im->add($mime);
		$im->done($mime);
	}
	ok($sock, 'sock created');
	$cmd = [ '-httpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, undef, { 3 => $sock });
	my $host = $sock->sockhost;
	my $port = $sock->sockport;
	{
		my $bad = tcp_connect($sock);
		print $bad "GETT / HTTP/1.0\r\n\r\n" or die;
		like(<$bad>, qr!\AHTTP/1\.[01] 405\b!, 'got 405 on bad req');
	}
	my $conn = tcp_connect($sock);
	ok($conn, 'connected');
	ok($conn->write("GET / HTTP/1.0\r\n\r\n"), 'wrote data to socket');
	{
		my $buf;
		ok($conn->read($buf, 4096), 'read some bytes');
		like($buf, qr!\AHTTP/1\.[01] 404\b!, 'got 404 response');
		is($conn->read($buf, 1), 0, "EOF");
	}

	is(xsys(qw(git clone -q --mirror),
			"http://$host:$port/$group", "$tmpdir/clone.git"),
		0, 'smart clone successful');

	# ensure dumb cloning works, too:
	is(xsys('git', "--git-dir=$maindir",
		qw(config http.uploadpack false)),
		0, 'disable http.uploadpack');
	is(xsys(qw(git clone -q --mirror),
			"http://$host:$port/$group", "$tmpdir/dumb.git"),
		0, 'clone successful');

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
	my $var = PublicInbox::Daemon::SO_ACCEPTFILTER();
	my $x = getsockopt($sock, SOL_SOCKET, $var);
	like($x, qr/\Ahttpready\0+\z/, 'got httpready accf for HTTP');
};

done_testing();

1;
