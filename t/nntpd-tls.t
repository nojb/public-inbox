# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Socket qw(SOCK_STREAM IPPROTO_TCP);
# IO::Poll and Net::NNTP are part of the standard library, but
# distros may split them off...
foreach my $mod (qw(DBD::SQLite IO::Socket::SSL Net::NNTP IO::Poll)) {
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
require PublicInbox::InboxWritable;
require PublicInbox::MIME;
require PublicInbox::SearchIdx;
my $version = 2; # v2 needs newer git
require_git('2.6') if $version >= 2;
my $tmpdir = tempdir('pi-nntpd-tls-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $mainrepo = "$tmpdir";
my $pi_config = "$tmpdir/pi_config";
my $group = 'test-nntpd-tls';
my $addr = $group . '@example.com';
my $nntpd = 'blib/script/public-inbox-nntpd';
my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Type => SOCK_STREAM,
	Listen => 1024,
);
my $starttls = IO::Socket::INET->new(%opts);
my $nntps = IO::Socket::INET->new(%opts);
my ($pid, $tail_pid);
END {
	foreach ($pid, $tail_pid) {
		kill 'TERM', $_ if defined $_;
	}
};

my $ibx = PublicInbox::Inbox->new({
	mainrepo => $mainrepo,
	name => 'nntpd-tls',
	version => $version,
	-primary_address => $addr,
	indexlevel => 'basic',
});
$ibx = PublicInbox::InboxWritable->new($ibx, {nproc=>1});
$ibx->init_inbox(0);
{
	open my $fh, '>', $pi_config or die "open: $!\n";
	print $fh <<EOF
[publicinbox "nntpd-tls"]
	mainrepo = $mainrepo
	address = $addr
	indexlevel = basic
	newsgroup = $group
EOF
	;
	close $fh or die "close: $!\n";
}

{
	my $im = $ibx->importer(0);
	my $mime = PublicInbox::MIME->new(do {
		open my $fh, '<', 't/data/0001.patch' or die;
		local $/;
		<$fh>
	});
	ok($im->add($mime), 'message added');
	$im->done;
	if ($version == 1) {
		my $s = PublicInbox::SearchIdx->new($ibx, 1);
		$s->index_sync;
	}
}

my $nntps_addr = $nntps->sockhost . ':' . $nntps->sockport;
my $starttls_addr = $starttls->sockhost . ':' . $starttls->sockport;
my $env = { PI_CONFIG => $pi_config };

for my $args (
	[ "--cert=$cert", "--key=$key",
		"-lnntps://$nntps_addr",
		"-lnntp://$starttls_addr" ],
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
	my $cmd = [ $nntpd, '-W0', @$args, "--stdout=$out", "--stderr=$err" ];
	$pid = spawn_listener($env, $cmd, [ $starttls, $nntps ]);
	my %o = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	my $expect = { $group => [qw(1 1 n)] };

	# start negotiating a slow TLS connection
	my $slow = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => $nntps_addr,
		Type => SOCK_STREAM,
		Blocking => 0,
	);
	$slow = IO::Socket::SSL->start_SSL($slow, SSL_startHandshake => 0, %o);
	my $slow_done = $slow->connect_SSL;
	diag('W: connect_SSL early OK, slow client test invalid') if $slow_done;
	my @poll = (fileno($slow), PublicInbox::TLS::epollbit());
	# we should call connect_SSL much later...

	# NNTPS
	my $c = Net::NNTP->new($nntps_addr, %o, SSL => 1);
	my $list = $c->list;
	is_deeply($list, $expect, 'NNTPS LIST works');
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

	# Net::NNTP won't let us do dumb things, but we need to test
	# dumb things, so use Net::Cmd directly:
	my $n = $c->command('STARTTLS')->response();
	is($n, Net::Cmd::CMD_ERROR(), 'error attempting STARTTLS again');
	is($c->code, 502, '502 according to RFC 4642 sec#2.2.1');

	# STARTTLS with bad hostname
	$o{SSL_hostname} = $o{SSL_verifycn_name} = 'server.invalid';
	$c = Net::NNTP->new($starttls_addr, %o);
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

	SKIP: {
		skip 'TCP_DEFER_ACCEPT is Linux-only', 2 if $^O ne 'linux';
		my $var = Socket::TCP_DEFER_ACCEPT();
		defined(my $x = getsockopt($nntps, IPPROTO_TCP, $var)) or die;
		ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set on NNTPS');
		defined($x = getsockopt($starttls, IPPROTO_TCP, $var)) or die;
		is(unpack('i', $x), 0, 'TCP_DEFER_ACCEPT is 0 on plain NNTP');
	};

	$c = undef;
	kill('TERM', $pid);
	is($pid, waitpid($pid, 0), 'nntpd exited successfully');
	is($?, 0, 'no error in exited process');
	$pid = undef;
	my $eout = eval {
		open my $fh, '<', $err or die "open $err failed: $!";
		local $/;
		<$fh>;
	};
	unlike($eout, qr/wide/i, 'no Wide character warnings');
	if (defined $tail_pid) {
		kill 'TERM', $tail_pid;
		waitpid($tail_pid, 0);
		$tail_pid = undef;
	}
}
done_testing();
1;
