# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
foreach my $mod (qw(DBD::SQLite Search::Xapian Danga::Socket)) {
	eval "require $mod";
	plan skip_all => "$mod missing for nntpd.t" if $@;
}
require PublicInbox::SearchIdx;
require PublicInbox::Msgmap;
use Cwd;
use Email::Simple;
use IO::Socket;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
use File::Temp qw/tempdir/;
use Net::NNTP;

my $tmpdir = tempdir('pi-nntpd-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $home = "$tmpdir/pi-home";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $maindir = "$tmpdir/main.git";
my $group = 'test-nntpd';
my $addr = $group . '@example.com';
my $cfgpfx = "publicinbox.$group";
my $nntpd = 'blib/script/public-inbox-nntpd';
my $init = 'blib/script/public-inbox-init';
my $index = 'blib/script/public-inbox-index';
use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Git';

my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Type => SOCK_STREAM,
	Listen => 1024,
);
my $sock = IO::Socket::INET->new(%opts);
my $pid;
my $len;
END { kill 'TERM', $pid if defined $pid };
{
	local $ENV{HOME} = $home;
	system($init, $group, $maindir, 'http://example.com/', $addr);
	my $len;

	# ensure successful message delivery
	{
		my $mime = Email::MIME->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 06:06:06 +0000

nntp
EOF
		$mime->header_set('List-Id', "<$addr>");
		$len = length($mime->as_string);
		my $git = PublicInbox::Git->new($maindir);
		my $im = PublicInbox::Import->new($git, 'test', $addr);
		$im->add($mime);
		$im->done;
		is(0, system($index, $maindir), 'indexed git dir');
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
		exec $nntpd, "--stdout=$out", "--stderr=$err";
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked nntpd process successfully');
	$! = 0;
	fcntl($sock, F_SETFD, $fl |= FD_CLOEXEC);
	ok(! $!, 'no error from fcntl(F_SETFD)');
	my $host_port = $sock->sockhost . ':' . $sock->sockport;
	my $n = Net::NNTP->new($host_port);
	my $list = $n->list;
	is_deeply($list, { $group => [ qw(1 1 n) ] }, 'LIST works');
	is_deeply([$n->group($group)], [ qw(0 1 1), $group ], 'GROUP works');

	%opts = (
		PeerAddr => $host_port,
		Proto => 'tcp',
		Type => SOCK_STREAM,
		Timeout => 1,
	);
	my $mid = '<nntp@example.com>';
	my %xhdr = (
		'message-id' => $mid,
		'subject' => 'hihi',
		'date' => 'Thu, 01 Jan 1970 06:06:06 +0000',
		'from' => 'Me <me@example.com>',
		'to' => 'You <you@example.com>',
		'cc' => $addr,
		'xref' => "example.com $group:1"
	);

	my $s = IO::Socket::INET->new(%opts);
	sysread($s, my $buf, 4096);
	is($buf, "201 server ready - post via email\r\n", 'got greeting');
	$s->autoflush(1);

	while (my ($k, $v) = each %xhdr) {
		is_deeply($n->xhdr("$k $mid"), { $mid => $v },
			  "XHDR $k by message-id works");
		is_deeply($n->xhdr("$k 1"), { 1 => $v },
			  "$k by article number works");
		is_deeply($n->xhdr("$k 1-"), { 1 => $v },
			  "$k by article range works");
		next;
		$buf = '';
		syswrite($s, "HDR $k $mid\r\n");
		do {
			sysread($s, $buf, 4096, length($buf));
		} until ($buf =~ /\r\n\.\r\n\z/);
		my @r = split("\r\n", $buf);
		like($r[0], qr/\A224 /, '224 response for HDR');
		is($r[1], "0 $v", 'got expected response for HDR');
	}

	{
		my $nogroup = Net::NNTP->new($host_port);
		while (my ($k, $v) = each %xhdr) {
			is_deeply($nogroup->xhdr("$k $mid"), { $mid => $v },
				  "$k by message-id works without group");
		}
	}

	is_deeply($n->xover('1-'), {
		'1' => ['hihi',
			'Me <me@example.com>',
			'Thu, 01 Jan 1970 06:06:06 +0000',
			'<nntp@example.com>',
			'',
			$len,
			'1' ] }, "XOVER range works");

	is_deeply($n->xover('1'), {
		'1' => ['hihi',
			'Me <me@example.com>',
			'Thu, 01 Jan 1970 06:06:06 +0000',
			'<nntp@example.com>',
			'',
			$len,
			'1' ] }, "XOVER by article works");

	{
		syswrite($s, "OVER $mid\r\n");
		$buf = '';
		do {
			sysread($s, $buf, 4096, length($buf));
		} until ($buf =~ /\r\n\.\r\n\z/);
		my @r = split("\r\n", $buf);
		like($r[0], qr/^224 /, 'got 224 response for OVER');
		is($r[1], "0\thihi\tMe <me\@example.com>\t" .
			"Thu, 01 Jan 1970 06:06:06 +0000\t" .
			"$mid\t\t$len\t1", 'OVER by Message-ID works');
		is($r[2], '.', 'correctly terminated response');
	}

	is_deeply($n->xhdr(qw(Cc 1-)), { 1 => 'test-nntpd@example.com' },
		 'XHDR Cc 1- works');
	is_deeply($n->xhdr(qw(References 1-)), { 1 => '' },
		 'XHDR References 1- works (empty string)');
	is_deeply($n->xhdr(qw(list-id 1-)), {},
		 'XHDR on invalid header returns empty');

	{
		setsockopt($s, IPPROTO_TCP, TCP_NODELAY, 1);
		syswrite($s, 'HDR List-id 1-');
		select(undef, undef, undef, 0.15);
		ok(kill('TERM', $pid), 'killed nntpd');
		select(undef, undef, undef, 0.15);
		syswrite($s, "\r\n");
		$buf = '';
		do {
			sysread($s, $buf, 4096, length($buf));
		} until ($buf =~ /\r\n\z/);
		my @r = split("\r\n", $buf);
		like($r[0], qr/^5\d\d /,
			'got 5xx response for unoptimized HDR');
		is(scalar @r, 1, 'only one response line');
	}

	is($pid, waitpid($pid, 0), 'nntpd exited successfully');
	is($?, 0, 'no error in exited process');
}

done_testing();

1;
