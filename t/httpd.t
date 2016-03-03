# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;

foreach my $mod (qw(Plack::Util Plack::Request Plack::Builder Danga::Socket
			HTTP::Parser::XS HTTP::Date HTTP::Status)) {
	eval "require $mod";
	plan skip_all => "$mod missing for httpd.t" if $@;
}
use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;
use IO::Socket;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
use IPC::Run;

# FIXME: too much setup
my $tmpdir = tempdir('pi-httpd-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $home = "$tmpdir/pi-home";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $pi_home = "$home/.public-inbox";
my $pi_config = "$pi_home/config";
my $maindir = "$tmpdir/main.git";
my $main_bin = getcwd()."/t/main-bin";
my $main_path = "$main_bin:$ENV{PATH}"; # for spamc ham mock
my $group = 'test-httpd';
my $addr = $group . '@example.com';
my $cfgpfx = "publicinbox.$group";
my $failbox = "$home/fail.mbox";
local $ENV{PI_EMERGENCY} = $failbox;
my $mda = 'blib/script/public-inbox-mda';
my $httpd = 'blib/script/public-inbox-httpd';
my $init = 'blib/script/public-inbox-init';

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
	local $ENV{HOME} = $home;
	ok(!system($init, $group, $maindir, 'http://example.com/', $addr),
		'init ran properly');

	# ensure successful message delivery
	{
		local $ENV{ORIGINAL_RECIPIENT} = $addr;
		my $in = <<EOF;
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 06:06:06 +0000

nntp
EOF
		local $ENV{PATH} = $main_path;
		IPC::Run::run([$mda], \$in);
		is(0, $?, 'ran MDA correctly');
	}
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
		exec $httpd, "--stdout=$out", "--stderr=$err";
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked httpd process successfully');
	$! = 0;
	fcntl($sock, F_SETFD, $fl |= FD_CLOEXEC);
	ok(! $!, 'no error from fcntl(F_SETFD)');
	my $host = $sock->sockhost;
	my $port = $sock->sockport;
	my $conn = IO::Socket::INET->new(PeerAddr => $host,
				PeerPort => $port,
				Proto => 'tcp',
				Type => SOCK_STREAM);
	ok($conn, 'connected');
	ok($conn->write("GET / HTTP/1.0\r\n\r\n"), 'wrote data to socket');
	{
		my $buf;
		ok($conn->read($buf, 4096), 'read some bytes');
		like($buf, qr!\AHTTP/1\.[01] 404\b!, 'got 404 response');
		is($conn->read($buf, 1), 0, "EOF");
	}

	is(system(qw(git clone -q --mirror),
			"http://$host:$port/$group", "$tmpdir/clone.git"),
		0, 'clone successful');
	ok(kill('TERM', $pid), 'killed httpd');
	$pid = undef;
	waitpid(-1, 0);

	is(system('git', "--git-dir=$tmpdir/clone.git",
		  qw(fsck --no-verbose)), 0,
		'fsck on cloned directory successful');
}

done_testing();

1;
