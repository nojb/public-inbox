# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Spawn qw(which);
require_mods(qw(DBD::SQLite));
require PublicInbox::InboxWritable;
use Email::Simple;
use IO::Socket;
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Net::NNTP;
use Sys::Hostname;

# FIXME: make easier to test both versions
my $version = $ENV{PI_TEST_VERSION} || 2;
require_git('2.6') if $version == 2;

my ($tmpdir, $for_destroy) = tmpdir();
my $home = "$tmpdir/pi-home";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $inboxdir = "$tmpdir/main.git";
my $group = 'test-nntpd';
my $addr = $group . '@example.com';
SKIP: {
	skip "git 2.6+ required for V2Writable", 1 if $version == 1;
	use_ok 'PublicInbox::V2Writable';
}

my %opts;
my $sock = tcp_server();
my $td;
my $len;

my $ibx = {
	inboxdir => $inboxdir,
	name => $group,
	version => $version,
	-primary_address => $addr,
	indexlevel => 'basic',
};
$ibx = PublicInbox::Inbox->new($ibx);
{
	local $ENV{HOME} = $home;
	my @cmd = ('-init', $group, $inboxdir, 'http://example.com/', $addr);
	push @cmd, "-V$version", '-Lbasic';
	ok(run_script(\@cmd), 'init OK');
	is(xsys(qw(git config), "--file=$home/.public-inbox/config",
			"publicinbox.$group.newsgroup", $group),
		0, 'enabled newsgroup');
	my $len;

	$ibx = PublicInbox::InboxWritable->new($ibx);
	my $im = $ibx->importer;

	# ensure successful message delivery
	{
		my $mime = Email::MIME->new(<<EOF);
To: =?utf-8?Q?El=C3=A9anor?= <you\@example.com>
From: =?utf-8?Q?El=C3=A9anor?= <me\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Content-Type: text/plain; charset=utf-8
Subject: Testing for	=?utf-8?Q?El=C3=A9anor?=
Date: Thu, 01 Jan 1970 06:06:06 +0000
Content-Transfer-Encoding: 8bit
References: <ref	tab	squeezed>

This is a test message for El\xc3\xa9anor
EOF
		my $list_id = $addr;
		$list_id =~ s/@/./;
		$mime->header_set('List-Id', "<$list_id>");
		$len = length($mime->as_string);
		$im->add($mime);
		$im->done;
		if ($version == 1) {
			ok(run_script(['-index', $ibx->{inboxdir}]),
				'indexed v1');
		}
	}

	ok($sock, 'sock created');
	my $cmd = [ '-nntpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, undef, { 3 => $sock });
	my $host_port = $sock->sockhost . ':' . $sock->sockport;
	my $n = Net::NNTP->new($host_port);
	my $list = $n->list;
	is_deeply($list, { $group => [ qw(1 1 n) ] }, 'LIST works');
	is_deeply([$n->group($group)], [ qw(0 1 1), $group ], 'GROUP works');
	is_deeply($n->listgroup($group), [1], 'listgroup OK');
	# TODO: Net::NNTP::listgroup does not support range at the moment

	{
		my $expect = [ qw(Subject: From: Date: Message-ID:
				References: Bytes: Lines: Xref:full) ];
		is_deeply($n->overview_fmt, $expect,
			'RFC3977 8.4.2 compliant LIST OVERVIEW.FMT');
	}
	SKIP: {
		$n->can('starttls') or
			skip('Net::NNTP too old to support STARTTLS', 2);
		require_mods('IO::Socket::SSL', 2);
		eval {
			IO::Socket::SSL->VERSION(2.007);
		} or skip(<<EOF, 2);
IO::Socket::SSL <2.007 not supported by Net::NNTP
EOF
		ok(!$n->starttls, 'STARTTLS fails when unconfigured');
		is($n->code, 580, 'got 580 code on server w/o TLS');
	};

	my $mid = '<nntp@example.com>';
	my %xhdr = (
		'message-id' => $mid,
		subject => "Testing for El\xc3\xa9anor",
		'date' => 'Thu, 01 Jan 1970 06:06:06 +0000',
		'from' => "El\xc3\xa9anor <me\@example.com>",
		'to' => "El\xc3\xa9anor <you\@example.com>",
		'cc' => $addr,
		'xref' => hostname . " $group:1",
		'references' => '<reftabsqueezed>',
	);

	my $s = tcp_connect($sock);
	sysread($s, my $buf, 4096);
	is($buf, "201 " . hostname . " ready - post via email\r\n",
		'got greeting');

	ok(syswrite($s, "   \r\n"), 'wrote spaces');
	ok(syswrite($s, "\r\n"), 'wrote nothing');
	syswrite($s, "NEWGROUPS\t19990424 000000 \033GMT\007\r\n");
	is(0, sysread($s, $buf, 4096), 'GOT EOF on cntrl');

	$s = tcp_connect($sock);
	sysread($s, $buf, 4096);
	is($buf, "201 " . hostname . " ready - post via email\r\n",
		'got greeting');

	syswrite($s, "CAPABILITIES\r\n");
	$buf = read_til_dot($s);
	like($buf, qr/\r\nVERSION 2\r\n/s, 'CAPABILITIES works');
	unlike($buf, qr/STARTTLS/s, 'STARTTLS not advertised');
	my $deflate_capa = qr/\r\nCOMPRESS DEFLATE\r\n/;
	if (eval { require Compress::Raw::Zlib }) {
		like($buf, $deflate_capa, 'DEFLATE advertised');
	} else {
		unlike($buf, $deflate_capa,
			'DEFLATE not advertised (Compress::Raw::Zlib missing)');
	}

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
			'<reftabsqueezed>',
			$len,
			'1',
			'Xref: '. hostname . ' test-nntpd:1'] },
		"XOVER range works");

	is_deeply($n->xover('1'), {
		'1' => ["Testing for El\xc3\xa9anor",
			"El\xc3\xa9anor <me\@example.com>",
			'Thu, 01 Jan 1970 06:06:06 +0000',
			'<nntp@example.com>',
			'<reftabsqueezed>',
			$len,
			'1',
			'Xref: '. hostname . ' test-nntpd:1'] },
		"XOVER by article works");

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
			"$mid\t<reftabsqueezed>\t$len\t1" .
			"\tXref: " . hostname . " test-nntpd:0",
			'OVER by Message-ID works');
		is($r[2], '.', 'correctly terminated response');
	}

	is_deeply($n->xhdr(qw(Cc 1-)), { 1 => 'test-nntpd@example.com' },
		 'XHDR Cc 1- works');
	is_deeply($n->xhdr(qw(References 1-)), { 1 => '<reftabsqueezed>' },
		 'XHDR References 1- works)');
	is_deeply($n->xhdr(qw(list-id 1-)), {},
		 'XHDR on invalid header returns empty');

	my $mids = $n->newnews(0, '*');
	is_deeply($mids, ['<nntp@example.com>'], 'NEWNEWS works');
	{
		my $t0 = time;
		my $date = $n->date;
		my $t1 = time;
		ok($date >= $t0, 'valid date after start');
		ok($date <= $t1, 'valid date before stop');
	}
	if ('leafnode interop') {
		my $for_leafnode = PublicInbox::MIME->new(<<"");
From: longheader\@example.com
To: $addr
Subject: none
Date: Fri, 02 Oct 1993 00:00:00 +0000

		my $long_hdr = 'for-leafnode-'.('y'x200).'@example.com';
		$for_leafnode->header_set('Message-ID', "<$long_hdr>");
		$im->add($for_leafnode);
		$im->done;
		if ($version == 1) {
			ok(run_script(['-index', $ibx->{inboxdir}]),
				'indexed v1');
		}
		my $hdr = $n->head("<$long_hdr>");
		my $expect = qr/\AMessage-ID: /i . qr/\Q<$long_hdr>\E/;
		ok(scalar(grep(/$expect/, @$hdr)), 'Message-ID not folded');
		ok(scalar(grep(/^Path:/, @$hdr)), 'Path: header found');

		# it's possible for v2 messages to have 2+ Message-IDs,
		# but leafnode can't handle it
		if ($version != 1) {
			my @mids = ("<$long_hdr>", '<2mid@wtf>');
			$for_leafnode->header_set('Message-ID', @mids);
			$for_leafnode->body_set('not-a-dupe');
			my $warn = '';
			local $SIG{__WARN__} = sub { $warn .= join('', @_) };
			$im->add($for_leafnode);
			$im->done;
			like($warn, qr/reused/, 'warned for reused MID');
			$hdr = $n->head('<2mid@wtf>');
			my @hmids = grep(/\AMessage-ID: /i, @$hdr);
			is(scalar(@hmids), 1, 'Single Message-ID in header');
			like($hmids[0], qr/: <2mid\@wtf>/, 'got expected mid');
		}
	}

	# pipelined requests:
	{
		my $nreq = 90;
		syswrite($s, "GROUP $group\r\n");
		my $res = <$s>;
		my $rdr = fork;
		if ($rdr == 0) {
			use POSIX qw(_exit);
			for (1..$nreq) {
				<$s> =~ /\A224 / or _exit(1);
				<$s> =~ /\A1/ or _exit(2);
				<$s> eq ".\r\n" or _exit(3);
			}
			_exit(0);
		}
		for (1..$nreq) {
			syswrite($s, "XOVER 1\r\n");
		}
		is($rdr, waitpid($rdr, 0), 'reader done');
		is($? >> 8, 0, 'no errors');
	}
	SKIP: {
		if ($INC{'Search/Xapian.pm'} && ($ENV{TEST_RUN_MODE}//2)) {
			skip 'Search/Xapian.pm pre-loaded (by t/run.perl?)', 1;
		}
		my $lsof = which('lsof') or skip 'lsof missing', 1;
		my $rdr = { 2 => \(my $null) };
		my @of = xqx([$lsof, '-p', $td->{pid}], undef, $rdr);
		skip('lsof broken', 1) if (!scalar(@of) || $?);
		my @xap = grep m!Search/Xapian!, @of;
		is_deeply(\@xap, [], 'Xapian not loaded in nntpd');
	}
	{
		setsockopt($s, IPPROTO_TCP, TCP_NODELAY, 1);
		syswrite($s, 'HDR List-id 1-');
		select(undef, undef, undef, 0.15);
		ok($td->kill, 'killed nntpd');
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
	$td->join;
	is($?, 0, 'no error in exited process');
	my $eout = do {
		open my $fh, '<', $err or die "open $err failed: $!";
		local $/;
		<$fh>;
	};
	unlike($eout, qr/wide/i, 'no Wide character warnings');
}

$td = undef;
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
