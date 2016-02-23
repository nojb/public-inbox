# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# note: our HTTP server should be standalone and capable of running
# generic Rack apps.
use strict;
use warnings;
use Test::More;

foreach my $mod (qw(Plack::Util Plack::Request Plack::Builder Danga::Socket
			HTTP::Parser::XS HTTP::Date HTTP::Status)) {
	eval "require $mod";
	plan skip_all => "$mod missing for httpd-corner.t" if $@;
}

use Digest::SHA qw(sha1_hex);
use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;
use IO::Socket;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
my $tmpdir = tempdir(CLEANUP => 1);
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $httpd = 'blib/script/public-inbox-httpd';
my $psgi = getcwd()."/t/httpd-corner.psgi";
my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Type => SOCK_STREAM,
	Listen => 1024,
);
my $sock = IO::Socket::INET->new(%opts);
my $pid;
END { kill 'TERM', $pid if defined $pid };
{
	ok($sock, 'sock created');
	$! = 0;
	my $fl = fcntl($sock, F_GETFD, 0);
	ok(! $!, 'no error from fcntl(F_GETFD)');
	is($fl, FD_CLOEXEC, 'cloexec set by default (Perl behavior)');
	$pid = fork;
	if ($pid == 0) {
		use POSIX qw(dup2);
		# pretend to be systemd
		fcntl($sock, F_SETFD, $fl &= ~FD_CLOEXEC);
		dup2(fileno($sock), 3) or die "dup2 failed: $!\n";
		$ENV{LISTEN_PID} = $$;
		$ENV{LISTEN_FDS} = 1;
		exec $httpd, '-W0', "--stdout=$out", "--stderr=$err", $psgi;
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked httpd process successfully');
	$! = 0;
	fcntl($sock, F_SETFD, $fl |= FD_CLOEXEC);
	ok(! $!, 'no error from fcntl(F_SETFD)');
}

sub conn_for {
	my ($sock, $msg) = @_;
	my $conn = IO::Socket::INET->new(
				PeerAddr => $sock->sockhost,
				PeerPort => $sock->sockport,
				Proto => 'tcp',
				Type => SOCK_STREAM);
	ok($conn, "connected for $msg");
	$conn->autoflush(1);
	setsockopt($conn, IPPROTO_TCP, TCP_NODELAY, 1);
	return $conn;
}

sub delay { select(undef, undef, undef, shift || rand(0.02)) }

my $str = 'abcdefghijklmnopqrstuvwxyz';
my $len = length $str;
is($len, 26, 'got the alphabet');
my $check_self = sub {
	my ($conn) = @_;
	$conn->read(my $buf, 4096);
	my ($head, $body) = split(/\r\n\r\n/, $buf, 2);
	like($head, qr/\r\nContent-Length: 40\r\n/s, 'got expected length');
	is($body, sha1_hex($str), 'read expected body');
};

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
	my $r = $conn->read(my $buf, 66666);
	ok($r > 0, 'got non-empty response');
	like($buf, qr!HTTP/1\.\d 400 !, 'got 400 response');

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
	$r = $conn->read($buf, 66666);
	ok($r > 0, 'got non-empty response');
	like($buf, qr!HTTP/1\.\d 400 !, 'got 400 response');
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
	my $conn = conn_for($sock, '1.1 Connnection: close');
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

done_testing();

1;
