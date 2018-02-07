# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
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
my $nntpd = 'blib/script/public-inbox-nntpd';
my $init = 'blib/script/public-inbox-init';
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
	is(system(qw(git config), "--file=$home/.public-inbox/config",
			"publicinbox.$group.newsgroup", $group),
		0, 'enabled newsgroup');
	my $len;

	# ensure successful message delivery
	{
		my $mime = Email::MIME->new(<<EOF);
To: =?utf-8?Q?El=C3=A9anor?= <you\@example.com>
From: =?utf-8?Q?El=C3=A9anor?= <me\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Content-Type: text/plain; charset=utf-8
Subject: Testing for =?utf-8?Q?El=C3=A9anor?=
Date: Thu, 01 Jan 1970 06:06:06 +0000
Content-Transfer-Encoding: 8bit

This is a test message for El\xc3\xa9anor
EOF
		my $list_id = $addr;
		$list_id =~ s/@/./;
		$mime->header_set('List-Id', "<$list_id>");
		$len = length($mime->as_string);
		my $git = PublicInbox::Git->new($maindir);
		my $im = PublicInbox::Import->new($git, 'test', $addr);
		$im->add($mime);
		$im->done;
		my $s = PublicInbox::SearchIdx->new($maindir, 1);
		$s->index_sync;
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
		subject => "Testing for El\xc3\xa9anor",
		'date' => 'Thu, 01 Jan 1970 06:06:06 +0000',
		'from' => "El\xc3\xa9anor <me\@example.com>",
		'to' => "El\xc3\xa9anor <you\@example.com>",
		'cc' => $addr,
		'xref' => "example.com $group:1"
	);

	my $s = IO::Socket::INET->new(%opts);
	sysread($s, my $buf, 4096);
	is($buf, "201 server ready - post via email\r\n", 'got greeting');
	$s->autoflush(1);

	syswrite($s, "NEWGROUPS\t19990424 000000 \033GMT\007\r\n");
	is(0, sysread($s, $buf, 4096), 'GOT EOF on cntrl');

	$s = IO::Socket::INET->new(%opts);
	sysread($s, $buf, 4096);
	is($buf, "201 server ready - post via email\r\n", 'got greeting');
	$s->autoflush(1);

	syswrite($s, "NEWGROUPS 19990424 000000 GMT\r\n");
	$buf = read_til_dot($s);
	like($buf, qr/\A231 list of /, 'newgroups OK');

	while (my ($k, $v) = each %xhdr) {
		is_deeply($n->xhdr("$k $mid"), { $mid => $v },
			  "XHDR $k by message-id works");
		is_deeply($n->xhdr("$k 1"), { 1 => $v },
			  "$k by article number works");
		is_deeply($n->xhdr("$k 1-"), { 1 => $v },
			  "$k by article range works");
		$buf = '';
		syswrite($s, "HDR $k $mid\r\n");
		$buf = read_til_dot($s);
		my @r = split("\r\n", $buf);
		like($r[0], qr/\A225 /, '225 response for HDR');
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
		'1' => ["Testing for El\xc3\xa9anor",
			"El\xc3\xa9anor <me\@example.com>",
			'Thu, 01 Jan 1970 06:06:06 +0000',
			'<nntp@example.com>',
			'',
			$len,
			'1' ] }, "XOVER range works");

	is_deeply($n->xover('1'), {
		'1' => ["Testing for El\xc3\xa9anor",
			"El\xc3\xa9anor <me\@example.com>",
			'Thu, 01 Jan 1970 06:06:06 +0000',
			'<nntp@example.com>',
			'',
			$len,
			'1' ] }, "XOVER by article works");

	is_deeply($n->head(1), $n->head('<nntp@example.com>'), 'HEAD OK');
	is_deeply($n->body(1), $n->body('<nntp@example.com>'), 'BODY OK');
	is($n->body(1)->[0], "This is a test message for El\xc3\xa9anor\n",
		'body really matches');
	my $art = $n->article(1);
	is(ref($art), 'ARRAY', 'got array for ARTICLE');
	is_deeply($art, $n->article('<nntp@example.com>'), 'ARTICLE OK');
	is($n->article(999), undef, 'non-existent num');
	is($n->article('<non-existent@example>'), undef, 'non-existent mid');

	{
		syswrite($s, "OVER $mid\r\n");
		$buf = read_til_dot($s);
		my @r = split("\r\n", $buf);
		like($r[0], qr/^224 /, 'got 224 response for OVER');
		is($r[1], "0\tTesting for El\xc3\xa9anor\t" .
			"El\xc3\xa9anor <me\@example.com>\t" .
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
		my $t0 = time;
		my $date = $n->date;
		my $t1 = time;
		ok($date >= $t0, 'valid date after start');
		ok($date <= $t1, 'valid date before stop');
	}

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

	$n = $s = undef;
	is($pid, waitpid($pid, 0), 'nntpd exited successfully');
	my $eout = eval {
		local $/;
		open my $fh, '<', $err or die "open $err failed: $!";
		<$fh>;
	};
	is($?, 0, 'no error in exited process');
	unlike($eout, qr/wide/i, 'no Wide character warnings');
}

done_testing();

sub read_til_dot {
	my ($s) = @_;
	my $buf = '';
	do {
		sysread($s, $buf, 4096, length($buf));
	} until ($buf =~ /\r\n\.\r\n\z/);
	$buf;
}

1;
