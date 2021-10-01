# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# note: our HTTP server should be standalone and capable of running
# generic PSGI/Plack apps.
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Time::HiRes qw(gettimeofday tv_interval);
use PublicInbox::Spawn qw(spawn popen_rd);
require_mods(qw(Plack::Util Plack::Builder HTTP::Date HTTP::Status));
use Digest::SHA qw(sha1_hex);
use IO::Handle ();
use IO::Socket::UNIX;
use Fcntl qw(:seek);
use Socket qw(IPPROTO_TCP TCP_NODELAY SOL_SOCKET);
use POSIX qw(mkfifo);
use Carp ();
my ($tmpdir, $for_destroy) = tmpdir();
my $fifo = "$tmpdir/fifo";
ok(defined mkfifo($fifo, 0777), 'created FIFO');
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $psgi = "./t/httpd-corner.psgi";
my $sock = tcp_server() or die;
my @zmods = qw(PublicInbox::GzipFilter IO::Uncompress::Gunzip);

# Make sure we don't clobber socket options set by systemd or similar
# using socket activation:
my ($defer_accept_val, $accf_arg, $TCP_DEFER_ACCEPT);
if ($^O eq 'linux') {
	$TCP_DEFER_ACCEPT = eval { Socket::TCP_DEFER_ACCEPT() } // 9;
	setsockopt($sock, IPPROTO_TCP, $TCP_DEFER_ACCEPT, 5) or die;
	my $x = getsockopt($sock, IPPROTO_TCP, $TCP_DEFER_ACCEPT);
	defined $x or die "getsockopt: $!";
	$defer_accept_val = unpack('i', $x);
	if ($defer_accept_val <= 0) {
		die "unexpected TCP_DEFER_ACCEPT value: $defer_accept_val";
	}
} elsif ($^O eq 'freebsd' && system('kldstat -m accf_data >/dev/null') == 0) {
	require PublicInbox::Daemon;
	my $var = $PublicInbox::Daemon::SO_ACCEPTFILTER;
	$accf_arg = pack('a16a240', 'dataready', '');
	setsockopt($sock, SOL_SOCKET, $var, $accf_arg) or die "setsockopt: $!";
}

sub unix_server ($) {
	my $s = IO::Socket::UNIX->new(
		Listen => 1024,
		Type => Socket::SOCK_STREAM(),
		Local => $_[0],
	) or BAIL_OUT "bind + listen $_[0]: $!";
	$s->blocking(0);
	$s;
}

my $upath = "$tmpdir/s";
my $unix = unix_server($upath);
my $td;
my $spawn_httpd = sub {
	my (@args) = @_;
	my $cmd = [ '-httpd', @args, "--stdout=$out", "--stderr=$err", $psgi ];
	$td = start_script($cmd, undef, { 3 => $sock, 4 => $unix });
};

$spawn_httpd->();
if ('test worker death') {
	my $conn = conn_for($sock, 'killed worker');
	$conn->write("GET /pid HTTP/1.1\r\nHost:example.com\r\n\r\n");
	my $pid;
	while (defined(my $line = $conn->getline)) {
		next unless $line eq "\r\n";
		chomp($pid = $conn->getline);
		last;
	}
	like($pid, qr/\A[0-9]+\z/, '/pid response');
	is(kill('KILL', $pid), 1, 'killed worker');
	is($conn->getline, undef, 'worker died and EOF-ed client');

	$conn = conn_for($sock, 'respawned worker');
	$conn->write("GET /pid HTTP/1.0\r\n\r\n");
	ok($conn->read(my $buf, 8192), 'read response');
	my ($head, $body) = split(/\r\n\r\n/, $buf);
	chomp($body);
	like($body, qr/\A[0-9]+\z/, '/pid response');
	isnt($body, $pid, 'respawned worker');
}

{
	my $conn = conn_for($sock, 'streaming callback');
	$conn->write("GET /callback HTTP/1.0\r\n\r\n");
	ok($conn->read(my $buf, 8192), 'read response');
	my ($head, $body) = split(/\r\n\r\n/, $buf);
	is($body, "hello world\n", 'callback body matches expected');
}

{
	my $conn = conn_for($sock, 'getline-die');
	$conn->write("GET /getline-die HTTP/1.1\r\nHost: example.com\r\n\r\n");
	ok($conn->read(my $buf, 8192), 'read some response');
	like($buf, qr!HTTP/1\.1 200\b[^\r]*\r\n!, 'got some sort of header');
	is($conn->read(my $nil, 8192), 0, 'read EOF');
	$conn = undef;
	my $after = capture($err);
	is(scalar(grep(/GETLINE FAIL/, @$after)), 1, 'failure logged');
	is(scalar(grep(/CLOSE FAIL/, @$after)), 1, 'body->close not called');
}

{
	my $conn = conn_for($sock, 'close-die');
	$conn->write("GET /close-die HTTP/1.1\r\nHost: example.com\r\n\r\n");
	ok($conn->read(my $buf, 8192), 'read some response');
	like($buf, qr!HTTP/1\.1 200\b[^\r]*\r\n!, 'got some sort of header');
	is($conn->read(my $nil, 8192), 0, 'read EOF');
	$conn = undef;
	my $after = capture($err);
	is(scalar(grep(/GETLINE FAIL/, @$after)), 0, 'getline not failed');
	is(scalar(grep(/CLOSE FAIL/, @$after)), 1, 'body->close not called');
}

sub check_400 {
	my ($conn) = @_;
	my $r = $conn->read(my $buf, 8192);
	# ECONNRESET and $r==0 are both observed on FreeBSD 11.2
	if (!defined($r)) {
		ok($!{ECONNRESET}, 'ECONNRESET on read (BSD sometimes)');
	} elsif ($r > 0) {
		like($buf, qr!\AHTTP/1\.\d 400 !, 'got 400 response');
	} else {
		is($r, 0, 'got EOF (BSD sometimes)');
	}
	close($conn); # ensure we don't get SIGPIPE later
}

{
	local $SIG{PIPE} = 'IGNORE';
	my $conn = conn_for($sock, 'excessive header');
	$conn->write("GET /callback HTTP/1.0\r\n");
	foreach my $i (1..500000) {
		last unless $conn->write("X-xxxxxJunk-$i: omg\r\n");
	}
	ok(!$conn->write("\r\n"), 'broken request');
	check_400($conn);
}

{
	my $conn = conn_for($sock, 'excessive body Content-Length');
	my $n = (10 * 1024 * 1024) + 1;
	$conn->write("PUT /sha1 HTTP/1.0\r\nContent-Length: $n\r\n\r\n");
	my $r = $conn->read(my $buf, 8192);
	ok($r > 0, 'read response');
	my ($head, $body) = split(/\r\n\r\n/, $buf);
	like($head, qr/\b413\b/, 'got 413 response');
}

{
	my $conn = conn_for($sock, 'excessive body chunked');
	my $n = (10 * 1024 * 1024) + 1;
	$conn->write("PUT /sha1 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n");
	$conn->write("\r\n".sprintf("%x\r\n", $n));
	my $r = $conn->read(my $buf, 8192);
	ok($r > 0, 'read response');
	my ($head, $body) = split(/\r\n\r\n/, $buf);
	like($head, qr/\b413\b/, 'got 413 response');
}

{
	my $conn = conn_for($sock, '1.1 Transfer-Encoding bogus');
	$conn->write("PUT /sha1 HTTP/1.1\r\nTransfer-Encoding: bogus\r\n\r\n");
	$conn->read(my $buf, 4096);
	like($buf, qr!\AHTTP/1\.[0-9] 400 !, 'got 400 response on bogus TE');
}
{
	my $conn = conn_for($sock, '1.1 Content-Length bogus');
	$conn->write("PUT /sha1 HTTP/1.1\r\nContent-Length: 3.3\r\n\r\n");
	$conn->read(my $buf, 4096);
	like($buf, qr!\AHTTP/1\.[0-9] 400 !, 'got 400 response on bad length');
}

{
	my $req = "PUT /sha1 HTTP/1.1\r\nContent-Length: 3\r\n" .
			"Content-Length: 3\r\n\r\n";
	# this is stricter than it needs to be.  Due to the way
	# Plack::HTTPParser, PSGI specs, and how hash tables work in common
	# languages; it's not possible to tell the difference between folded
	# and intentionally bad commas (e.g. "Content-Length: 3, 3")
	if (0) {
		require Plack::HTTPParser; # XS or pure Perl
		require Data::Dumper;
		Plack::HTTPParser::parse_http_request($req, my $env = {});
		diag Data::Dumper::Dumper($env); # "Content-Length: 3, 3"
	}
	my $conn = conn_for($sock, '1.1 Content-Length dupe');
	$conn->write($req);
	$conn->read(my $buf, 4096);
	like($buf, qr!\AHTTP/1\.[0-9] 400 !, 'got 400 response on dupe length');
}

{
	my $conn = conn_for($sock, 'chunk with pipeline');
	my $n = 10;
	my $payload = 'b'x$n;
	$conn->write("PUT /sha1 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n");
	$conn->write("\r\n".sprintf("%x\r\n", $n));
	$conn->write($payload . "\r\n0\r\n\r\nGET /empty HTTP/1.0\r\n\r\n");
	$conn->read(my $buf, 4096);
	my $lim = 0;
	$lim++ while ($conn->read($buf, 4096, length($buf)) && $lim < 9);
	my $exp = sha1_hex($payload);
	like($buf, qr!\r\n\r\n${exp}HTTP/1\.0 200 OK\r\n!s,
		'chunk parser can handled pipelined requests');
}

# Unix domain sockets
{
	my $u = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $upath);
	ok($u, 'unix socket connected');
	$u->write("GET /host-port HTTP/1.0\r\n\r\n");
	$u->read(my $buf, 4096);
	like($buf, qr!\r\n\r\n127\.0\.0\.1 0\z!,
		'set REMOTE_ADDR and REMOTE_PORT for Unix socket');
}

sub conn_for {
	my ($dest, $msg) = @_;
	my $conn = tcp_connect($dest);
	ok($conn, "connected for $msg");
	setsockopt($conn, IPPROTO_TCP, TCP_NODELAY, 1);
	return $conn;
}

{
	my $conn = conn_for($sock, 'host-port');
	$conn->write("GET /host-port HTTP/1.0\r\n\r\n");
	$conn->read(my $buf, 4096);
	my ($head, $body) = split(/\r\n\r\n/, $buf);
	my ($addr, $port) = split(/ /, $body);
	is($addr, (tcp_host_port($conn))[0], 'host matches addr');
	is($port, $conn->sockport, 'port matches');
}

# graceful termination
{
	my $conn = conn_for($sock, 'graceful termination via slow header');
	$conn->write("GET /slow-header HTTP/1.0\r\n" .
			"X-Check-Fifo: $fifo\r\n\r\n");
	open my $f, '>', $fifo or die "open $fifo: $!\n";
	$f->autoflush(1);
	ok(print($f "hello\n"), 'wrote something to fifo');
	is($td->kill, 1, 'started graceful shutdown');
	ok(print($f "world\n"), 'wrote else to fifo');
	close $f or die "close fifo: $!\n";
	$conn->read(my $buf, 8192);
	my ($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr!\AHTTP/1\.[01] 200 OK!, 'got 200 for slow-header');
	is($body, "hello\nworld\n", 'read expected body');
	$td->join;
	is($?, 0, 'no error');
	$spawn_httpd->('-W0');
}

{
	my $conn = conn_for($sock, 'graceful termination via slow-body');
	$conn->write("GET /slow-body HTTP/1.0\r\n" .
			"X-Check-Fifo: $fifo\r\n\r\n");
	open my $f, '>', $fifo or die "open $fifo: $!\n";
	$f->autoflush(1);
	my $buf;
	$conn->sysread($buf, 8192);
	like($buf, qr!\AHTTP/1\.[01] 200 OK!, 'got 200 for slow-body');
	like($buf, qr!\r\n\r\n!, 'finished HTTP response header');

	foreach my $c ('a'..'c') {
		$c .= "\n";
		ok(print($f $c), 'wrote line to fifo');
		$conn->sysread($buf, 8192);
		is($buf, $c, 'got trickle for reading');
	}
	is($td->kill, 1, 'started graceful shutdown');
	ok(print($f "world\n"), 'wrote else to fifo');
	close $f or die "close fifo: $!\n";
	$conn->sysread($buf, 8192);
	is($buf, "world\n", 'read expected body');
	is($conn->sysread($buf, 8192), 0, 'got EOF from server');
	$td->join;
	is($?, 0, 'no error');
	$spawn_httpd->('-W0');
}

sub delay { select(undef, undef, undef, shift || rand(0.02)) }

my $str = 'abcdefghijklmnopqrstuvwxyz';
my $len = length $str;
is($len, 26, 'got the alphabet');
my $check_self = sub {
	my ($conn) = @_;
	vec(my $rbits = '', fileno($conn), 1) = 1;
	select($rbits, undef, undef, 30) or Carp::confess('timed out');
	$conn->read(my $buf, 4096);
	my ($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr/\r\nContent-Length: 40\r\n/s, 'got expected length');
	is($body, sha1_hex($str), 'read expected body');
};

SKIP: {
	my $curl = require_cmd('curl', 1) or skip('curl(1) missing', 4);
	my $base = 'http://'.tcp_host_port($sock);
	my $url = "$base/sha1";
	my ($r, $w);
	pipe($r, $w) or die "pipe: $!";
	my $cmd = [$curl, qw(--tcp-nodelay -T- -HExpect: -sSN), $url];
	open my $cout, '+>', undef or die;
	open my $cerr, '>', undef or die;
	my $rdr = { 0 => $r, 1 => $cout, 2 => $cerr };
	my $pid = spawn($cmd, undef, $rdr);
	close $r or die "close read pipe: $!";
	foreach my $c ('a'..'z') {
		print $w $c or die "failed to write to curl: $!";
		delay();
	}
	close $w or die "close write pipe: $!";
	waitpid($pid, 0);
	is($?, 0, 'curl exited successfully');
	is(-s $cerr, 0, 'no errors from curl');
	seek($cout, 0, SEEK_SET);
	is(<$cout>, sha1_hex($str), 'read expected body');

	my $fh = popen_rd([$curl, '-sS', "$base/async-big"]);
	my $n = 0;
	my $non_zero = 0;
	while (1) {
		my $r = sysread($fh, my $buf, 4096) or last;
		$n += $r;
		$buf =~ /\A\0+\z/ or $non_zero++;
	}
	close $fh or die "close curl pipe: $!";
	is($?, 0, 'curl succesful');
	is($n, 30 * 1024 * 1024, 'got expected output from curl');
	is($non_zero, 0, 'read all zeros');

	require_mods(@zmods, 4);
	my $buf = xqx([$curl, '-sS', "$base/psgi-return-gzip"]);
	is($?, 0, 'curl succesful');
	IO::Uncompress::Gunzip::gunzip(\$buf => \(my $out));
	is($out, "hello world\n");
	my $curl_rdr = { 2 => \(my $curl_err = '') };
	$buf = xqx([$curl, qw(-sSv --compressed),
			"$base/psgi-return-compressible"], undef, $curl_rdr);
	is($?, 0, 'curl --compressed successful');
	is($buf, "goodbye world\n", 'gzipped response as expected');
	like($curl_err, qr/\bContent-Encoding: gzip\b/,
		'curl got gzipped response');
}

{
	my $conn = conn_for($sock, 'psgi_return ENOENT');
	print $conn "GET /psgi-return-enoent HTTP/1.1\r\n\r\n" or die;
	my $buf = '';
	sysread($conn, $buf, 16384, length($buf)) until $buf =~ /\r\n\r\n/;
	like($buf, qr!HTTP/1\.[01] 500\b!, 'got 500 error on ENOENT');
}

{
	my $conn = conn_for($sock, '1.1 pipeline together');
	$conn->write("PUT /sha1 HTTP/1.1\r\nUser-agent: hello\r\n\r\n" .
			"PUT /sha1 HTTP/1.1\r\n\r\n");
	my $buf = '';
	my @r;
	until (scalar(@r) >= 2) {
		my $r = $conn->sysread(my $tmp, 4096);
		die $! unless defined $r;
		die "EOF <$buf>" unless $r;
		$buf .= $tmp;
		@r = ($buf =~ /\r\n\r\n([a-f0-9]{40})/g);
	}
	is(2, scalar @r, 'got 2 responses');
	my $i = 3;
	foreach my $hex (@r) {
		is($hex, sha1_hex(''), "read expected body $i");
		$i++;
	}
}

{
	my $conn = conn_for($sock, 'no TCP_CORK on empty body');
	$conn->write("GET /empty HTTP/1.1\r\nHost:example.com\r\n\r\n");
	my $buf = '';
	my $t0 = [ gettimeofday ];
	until ($buf =~ /\r\n\r\n/s) {
		$conn->sysread($buf, 4096, length($buf));
	}
	my $elapsed = tv_interval($t0, [ gettimeofday ]);
	ok($elapsed < 0.190, 'no 200ms TCP cork delay on empty body');
}

{
	my $conn = conn_for($sock, 'graceful termination during slow request');
	$conn->write("PUT /sha1 HTTP/1.0\r\nContent-Length: $len\r\n\r\n");

	# XXX ugh, want a reliable and non-intrusive way to detect
	# that the server has started buffering our partial request so we
	# can reliably test graceful termination.  Maybe making this and
	# similar tests dependent on Linux strace is a possibility?
	delay(0.1);

	is($td->kill, 1, 'start graceful shutdown');
	my $n = 0;
	foreach my $c ('a'..'z') {
		$n += $conn->write($c);
	}
	ok(kill(0, $td->{pid}), 'graceful shutdown did not kill httpd');
	is($n, $len, 'wrote alphabet');
	$check_self->($conn);
	$td->join;
	is($?, 0, 'no error');
	$spawn_httpd->('-W0');
}

# various DoS attacks against the chunk parser:
{
	local $SIG{PIPE} = 'IGNORE';
	my $conn = conn_for($sock, '1.1 chunk header excessive');
	$conn->write("PUT /sha1 HTTP/1.1\r\nTransfer-Encoding:chunked\r\n\r\n");
	my $n = 0;
	my $w;
	while ($w = $conn->write('ffffffff')) {
		$n += $w;
	}
	ok($!, 'got error set in $!');
	is($w, undef, 'write error happened');
	ok($n > 0, 'was able to write');
	check_400($conn);
	$conn = conn_for($sock, '1.1 chunk trailer excessive');
	$conn->write("PUT /sha1 HTTP/1.1\r\nTransfer-Encoding:chunked\r\n\r\n");
	is($conn->syswrite("1\r\na"), 4, 'wrote first header + chunk');
	delay();
	$n = 0;
	while ($w = $conn->write("\r")) {
		$n += $w;
	}
	ok($!, 'got error set in $!');
	ok($n > 0, 'wrote part of chunk end (\r)');
	check_400($conn);
}

{
	my $conn = conn_for($sock, '1.1 chunked close trickle');
	$conn->write("PUT /sha1 HTTP/1.1\r\nConnection:close\r\n");
	$conn->write("Transfer-encoding: chunked\r\n\r\n");
	foreach my $x ('a'..'z') {
		delay();
		$conn->write('1');
		delay();
		$conn->write("\r");
		delay();
		$conn->write("\n");
		delay();
		$conn->write($x);
		delay();
		$conn->write("\r");
		delay();
		$conn->write("\n");
	}
	$conn->write('0');
	delay();
	$conn->write("\r");
	delay();
	$conn->write("\n");
	delay();
	$conn->write("\r");
	delay();
	$conn->write("\n");
	delay();
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, '1.1 chunked close');
	$conn->write("PUT /sha1 HTTP/1.1\r\nConnection:close\r\n");
	my $xlen = sprintf('%x', $len);
	$conn->write("Transfer-Encoding: chunked\r\n\r\n$xlen\r\n" .
		"$str\r\n0\r\n\r\n");
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, 'chunked body + pipeline');
	$conn->write("PUT /sha1 HTTP/1.1\r\n" .
			"Transfer-Encoding: chunked\r\n");
	delay();
	$conn->write("\r\n1\r\n");
	delay();
	$conn->write('a');
	delay();
	$conn->write("\r\n0\r\n\r\nPUT /sha1 HTTP/1.1\r\n");
	delay();

	my $buf = '';
	until ($buf =~ /\r\n\r\n[a-f0-9]{40}\z/) {
		$conn->sysread(my $tmp, 4096);
		$buf .= $tmp;
	}
	my ($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr/\r\nContent-Length: 40\r\n/s, 'got expected length');
	is($body, sha1_hex('a'), 'read expected body');

	$conn->write("Connection: close\r\n");
	$conn->write("Content-Length: $len\r\n\r\n$str");
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, 'trickle header, one-shot body + pipeline');
	$conn->write("PUT /sha1 HTTP/1.0\r\n" .
			"Connection: keep-alive\r\n");
	delay();
	$conn->write("Content-Length: $len\r\n\r\n${str}PUT");
	my $buf = '';
	until ($buf =~ /\r\n\r\n[a-f0-9]{40}\z/) {
		$conn->sysread(my $tmp, 4096);
		$buf .= $tmp;
	}
	my ($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr/\r\nContent-Length: 40\r\n/s, 'got expected length');
	is($body, sha1_hex($str), 'read expected body');

	$conn->write(" /sha1 HTTP/1.0\r\nContent-Length: $len\r\n\r\n$str");
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, 'trickle body');
	$conn->write("PUT /sha1 HTTP/1.0\r\n");
	$conn->write("Content-Length: $len\r\n\r\n");
	my $beg = substr($str, 0, 10);
	my $end = substr($str, 10);
	is($beg . $end, $str, 'substr setup correct');
	delay();
	$conn->write($beg);
	delay();
	$conn->write($end);
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, 'one-shot write');
	$conn->write("PUT /sha1 HTTP/1.0\r\n" .
			"Content-Length: $len\r\n\r\n$str");
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, 'trickle header, one-shot body');
	$conn->write("PUT /sha1 HTTP/1.0\r\n");
	delay();
	$conn->write("Content-Length: $len\r\n\r\n$str");
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, '1.1 Connection: close');
	$conn->write("PUT /sha1 HTTP/1.1\r\nConnection:close\r\n");
	delay();
	$conn->write("Content-Length: $len\r\n\r\n$str");
	$check_self->($conn);
}

{
	my $conn = conn_for($sock, '1.1 pipeline start');
	$conn->write("PUT /sha1 HTTP/1.1\r\n\r\nPUT");
	my $buf = '';
	until ($buf =~ /\r\n\r\n[a-f0-9]{40}\z/) {
		$conn->sysread(my $tmp, 4096);
		$buf .= $tmp;
	}
	my ($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr/\r\nContent-Length: 40\r\n/s, 'got expected length');
	is($body, sha1_hex(''), 'read expected body');

	# 2nd request
	$conn->write(" /sha1 HTTP/1.1\r\n\r\n");
	$buf = '';
	until ($buf =~ /\r\n\r\n[a-f0-9]{40}\z/) {
		$conn->sysread(my $tmp, 4096);
		$buf .= $tmp;
	}
	($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr/\r\nContent-Length: 40\r\n/s, 'got expected length');
	is($body, sha1_hex(''), 'read expected body #2');
}

SKIP: {
	skip 'TCP_DEFER_ACCEPT is Linux-only', 1 if $^O ne 'linux';
	my $var = $TCP_DEFER_ACCEPT;
	defined(my $x = getsockopt($sock, IPPROTO_TCP, $var)) or die;
	is(unpack('i', $x), $defer_accept_val,
		'TCP_DEFER_ACCEPT unchanged if previously set');
};
SKIP: {
	skip 'SO_ACCEPTFILTER is FreeBSD-only', 1 if $^O ne 'freebsd';
	skip 'accf_data not loaded: kldload accf_data' if !defined $accf_arg;
	my $var = $PublicInbox::Daemon::SO_ACCEPTFILTER;
	defined(my $x = getsockopt($sock, SOL_SOCKET, $var)) or die;
	is($x, $accf_arg, 'SO_ACCEPTFILTER unchanged if previously set');
};

SKIP: {
	skip 'only testing lsof(8) output on Linux', 1 if $^O ne 'linux';
	my $lsof = require_cmd('lsof', 1) or skip 'no lsof in PATH', 1;
	my $null_in = '';
	my $rdr = { 2 => \(my $null_err), 0 => \$null_in };
	my @lsof = xqx([$lsof, '-p', $td->{pid}], undef, $rdr);
	my $d = [ grep(/\(deleted\)/, @lsof) ];
	is_deeply($d, [], 'no lingering deleted inputs') or diag explain($d);

	# filter out pipes inherited from the parent
	my @this = xqx([$lsof, '-p', $$], undef, $rdr);
	my $bad;
	my $extract_inodes = sub {
		map {;
			my @f = split(' ', $_);
			my $inode = $f[-2];
			$bad = $_ if $inode !~ /\A[0-9]+\z/;
			$inode => 1;
		} grep (/\bpipe\b/, @_);
	};
	my %child = $extract_inodes->(@lsof);
	my %parent = $extract_inodes->(@this);
	skip("inode not in expected format: $bad", 1) if defined($bad);
	delete @child{(keys %parent)};
	is_deeply([], [keys %child], 'no extra pipes with -W0');
};

# ensure compatibility with other PSGI servers
SKIP: {
	require_mods(@zmods, qw(Plack::Test HTTP::Request::Common), 3);
	use_ok 'HTTP::Request::Common';
	use_ok 'Plack::Test';
	STDERR->flush;
	open my $olderr, '>&', \*STDERR or die "dup stderr: $!";
	open my $tmperr, '+>', undef or die;
	open STDERR, '>&', $tmperr or die;
	STDERR->autoflush(1);
	my $app = require $psgi;
	test_psgi($app, sub {
		my ($cb) = @_;
		my $req = GET('http://example.com/psgi-return-gzip');
		my $res = $cb->($req);
		my $buf = $res->content;
		IO::Uncompress::Gunzip::gunzip(\$buf => \(my $out));
		is($out, "hello world\n", 'got expected output');

		$req = GET('http://example.com/psgi-return-enoent');
		$res = $cb->($req);
		is($res->code, 500, 'got error on ENOENT');
		seek($tmperr, 0, SEEK_SET) or die;
		my $errbuf = do { local $/; <$tmperr> };
		like($errbuf, qr/this-better-not-exist/,
			'error logged about missing command');
	});
	open STDERR, '>&', $olderr or die "restore stderr: $!";
}

done_testing();

sub capture {
	my ($f) = @_;
	open my $fh, '+<', $f or die "failed to open $f: $!\n";
	local $/ = "\n";
	my @r = <$fh>;
	truncate($fh, 0) or die "truncate failed on $f: $!\n";
	\@r
}

1;
