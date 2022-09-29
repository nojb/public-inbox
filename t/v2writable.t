# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
use PublicInbox::ContentHash qw(content_digest content_hash);
use PublicInbox::TestCommon;
use Cwd qw(abs_path);
require_git(2.6);
require_mods(qw(DBD::SQLite Search::Xapian));
local $ENV{HOME} = abs_path('t');
use_ok 'PublicInbox::V2Writable';
umask 007;
my ($inboxdir, $for_destroy) = tmpdir();
my $ibx = {
	inboxdir => $inboxdir,
	name => 'test-v2writable',
	version => 2,
	-no_fsync => 1,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $mime = PublicInbox::Eml->new(<<'EOF');
From: a@example.com
To: test@example.com
Subject: this is a subject
Message-ID: <a-mid@b>
Date: Fri, 02 Oct 1993 00:00:00 +0000

hello world
EOF
my $im = PublicInbox::V2Writable->new($ibx, {nproc => 1});
is($im->{shards}, 1, 'one shard when forced');
ok($im->add($mime), 'ordinary message added');
foreach my $f ("$inboxdir/msgmap.sqlite3",
		glob("$inboxdir/xap*/*"),
		glob("$inboxdir/xap*/*/*")) {
	my @st = stat($f);
	my ($bn) = (split(m!/!, $f))[-1];
	is($st[2] & 07777, -f _ ? 0660 : 0770,
		"default sharedRepository respected for $bn");
}

my $git0;

if ('ensure git configs are correct') {
	my @cmd = (qw(git config), "--file=$inboxdir/all.git/config",
		qw(core.sharedRepository 0644));
	is(xsys(@cmd), 0, "set sharedRepository in all.git");
	$git0 = PublicInbox::Git->new("$inboxdir/git/0.git");
	chomp(my $v = $git0->qx(qw(config core.sharedRepository)));
	is($v, '0644', 'child repo inherited core.sharedRepository');
	chomp($v = $git0->qx(qw(config --bool repack.writeBitmaps)));
	is($v, 'true', 'child repo inherited repack.writeBitmaps');
}

{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	is($im->add($mime), undef, 'obvious duplicate rejected');
	is(scalar(@warn), 0, 'no warning about resent message');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>', '<c@d>');
	is($im->add($mime), undef, 'secondary MID ignored if first matches');
	my $sec = PublicInbox::Eml->new($mime->as_string);
	$sec->header_set('Date');
	$sec->header_set('Message-Id', '<a-mid@b>', '<c@d>');
	ok($im->add($sec), 'secondary MID used if data is different');
	like(join(' ', @warn), qr/mismatched/, 'warned about mismatch');
	like(join(' ', @warn), qr/alternative/, 'warned about alternative');
	is_deeply([ '<a-mid@b>', '<c@d>' ],
		[ $sec->header_obj->header_raw('Message-Id') ],
		'no new Message-Id added');

	my $sane_mid = qr/\A<[\w\-\.]+\@\w+>\z/;
	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>');
	$mime->body_set('different');
	ok($im->add($mime), 'reused mid ok');
	like(join(' ', @warn), qr/reused/, 'warned about reused MID');
	my @mids = $mime->header_obj->header_raw('Message-Id');
	is($mids[0], '<a-mid@b>', 'original mid not changed');
	like($mids[1], $sane_mid, 'new MID added');
	is(scalar(@mids), 2, 'only one new MID added');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>');
	$mime->body_set('this one needs a random mid');
	my $hdr = $mime->header_obj;
	my $gen = PublicInbox::Import::digest2mid(content_digest($mime), $hdr);
	unlike($gen, qr![\+/=]!, 'no URL-unfriendly chars in Message-Id');
	my $fake = PublicInbox::Eml->new($mime->as_string);
	$fake->header_set('Message-Id', "<$gen>");
	ok($im->add($fake), 'fake added easily');
	is_deeply(\@warn, [], 'no warnings from a faker');
	ok($im->add($mime), 'random MID made');
	like(join(' ', @warn), qr/using random/, 'warned about using random');
	@mids = $mime->header_obj->header_raw('Message-Id');
	is($mids[0], '<a-mid@b>', 'original mid not changed');
	like($mids[1], $sane_mid, 'new MID added');
	is(scalar(@mids), 2, 'only one new MID added');

	@warn = ();
	$mime->header_set('Message-Id');
	ok($im->add($mime), 'random MID made for MID free message');
	@mids = $mime->header_obj->header_raw('Message-Id');
	like($mids[0], $sane_mid, 'mid was generated');
	is(scalar(@mids), 1, 'new generated');

	@warn = ();
	$mime->header_set('Message-Id', '<space@ (NXDOMAIN) >');
	ok($im->add($mime), 'message added with space in Message-Id');
	is_deeply([], \@warn);
}

{
	$mime->header_set('Message-Id', '<abcde@1>', '<abcde@2>');
	$mime->header_set('X-Alt-Message-Id', '<alt-id-for-nntp>');
	$mime->header_set('References', '<zz-mid@b>');
	ok($im->add($mime), 'message with multiple Message-ID');
	$im->done;
	my $total = $ibx->over->dbh->selectrow_array(<<'');
SELECT COUNT(*) FROM over WHERE num > 0

	is($ibx->mm->num_highwater, $total, 'got expected highwater value');
	my $mset1 = $ibx->search->reopen->mset('m:abcde@1');
	is($mset1->size, 1, 'message found by first MID');
	my $mset2 = $ibx->search->mset('m:abcde@2');
	is($mset2->size, 1, 'message found by second MID');
	is((($mset1->items)[0])->get_docid, (($mset2->items)[0])->get_docid,
		'same document') if ($mset1->size);

	my $alt = $ibx->search->mset('m:alt-id-for-nntp');
	is($alt->size, 1, 'message found by alt MID (NNTP)');
	is((($alt->items)[0])->get_docid, (($mset1->items)[0])->get_docid,
		'same document') if ($mset1->size);
	$mime->header_set('X-Alt-Message-Id');

	my %uniq;
	for my $mid (qw(abcde@1 abcde@2 alt-id-for-nntp)) {
		my $msgs = $ibx->over->get_thread($mid);
		my $key = join(' ', sort(map { $_->{num} } @$msgs));
		$uniq{$key}++;
	}
	is(scalar(keys(%uniq)), 1, 'all alt Message-ID queries give same smsg');
	is_deeply([values(%uniq)], [3], '3 queries, 3 results');
}

{
	require_mods('Net::NNTP', 1);
	my $err = "$inboxdir/stderr.log";
	my $out = "$inboxdir/stdout.log";
	my $group = 'inbox.comp.test.v2writable';
	my $pi_config = "$inboxdir/pi_config";
	open my $fh, '>', $pi_config or die "open: $!\n";
	print $fh <<EOF
[publicinbox "test-v2writable"]
	inboxdir = $inboxdir
	version = 2
	address = test\@example.com
	newsgroup = $group
EOF
	;
	close $fh or die "close: $!\n";
	my $sock = tcp_server();
	my $len;
	my $cmd = [ '-nntpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	my $env = { PI_CONFIG => $pi_config };
	my $td = start_script($cmd, $env, { 3 => $sock });
	my $host_port = tcp_host_port($sock);
	my $n = Net::NNTP->new($host_port);
	$n->group($group);
	my $x = $n->xover('1-');
	my %uniq;
	foreach my $num (sort { $a <=> $b } keys %$x) {
		my $mid = $x->{$num}->[3];
		is($uniq{$mid}++, 0, "MID for $num is unique in XOVER");
		is_deeply($n->xhdr('Message-ID', $num),
			 { $num => $mid }, "XHDR lookup OK on num $num");

		# FIXME PublicInbox::NNTP (server) doesn't handle spaces in
		# Message-ID, but neither does Net::NNTP (client)
		next if $mid =~ / /;

		is_deeply($n->xhdr('Message-ID', $mid),
			 { $mid => $mid }, "XHDR lookup OK on MID $mid ($num)");
	}
	my %nn;
	foreach my $mid (@{$n->newnews(0, $group)}) {
		is($nn{$mid}++, 0, "MID is unique in NEWNEWS");
	}
	is_deeply([sort keys %nn], [sort keys %uniq]);

	my %lg;
	foreach my $num (@{$n->listgroup($group)}) {
		is($lg{$num}++, 0, "num is unique in LISTGROUP");
	}
	is_deeply([sort keys %lg], [sort keys %$x],
		'XOVER and LISTGROUPS return the same article numbers');

	my $xref = $n->xhdr('Xref', '1-');
	is_deeply([sort keys %lg], [sort keys %$xref], 'Xref range OK');

	my $mids = $n->xhdr('Message-ID', '1-');
	is_deeply([sort keys %lg], [sort keys %$xref], 'Message-ID range OK');

	my $rover = $n->xrover('1-');
	is_deeply([sort keys %lg], [sort keys %$rover], 'XROVER range OK');
};
{
	my @log = qw(log --no-decorate --no-abbrev --no-notes --no-color);
	my @before = $git0->qx(@log, qw(--pretty=oneline));
	my $before = $git0->qx(@log, qw(--pretty=raw --raw -r));
	$im = PublicInbox::V2Writable->new($ibx, {nproc => 2});
	is($im->{shards}, 1, 'detected single shard from previous');
	my ($mark, $rm_mime, $smsg) = $im->remove($mime, 'test removal');
	is(content_hash($rm_mime), content_hash($mime),
			'removed object returned matches');
	ok(defined($mark), 'mark set');
	$im->done;
	my @after = $git0->qx(@log, qw(--pretty=oneline));
	my $tip = shift @after;
	like($tip, qr/\A[a-f0-9]+ test removal\n\z/s,
		'commit message propagated to git');
	is_deeply(\@after, \@before, 'only one commit written to git');
	my $mid = $smsg->{mid};
	is($ibx->mm->num_for($mid), undef, 'no longer in Msgmap by mid');
	my $num = $smsg->{num};
	like($num, qr/\A\d+\z/, 'numeric number in return message');
	is($ibx->mm->mid_for($num), undef, 'no longer in Msgmap by num');
	my $mset = $ibx->search->reopen->mset('m:'.$mid);
	is($mset->size, 0, 'no longer found in Xapian');
	my @log1 = (@log, qw(-1 --pretty=raw --raw -r --no-renames));
	is($ibx->over->get_art($num), undef,
		'removal propagated to Over DB');

	my $after = $git0->qx(@log1);
	if ($after =~ m!( [a-f0-9]+ )A\td$!m) {
		my $oid = $1;
		ok(index($before, $oid) > 0, 'no new blob introduced');
	} else {
		fail('failed to extract blob from log output');
	}
	is($im->remove($mime, 'test removal'), undef,
		'remove is idempotent');
	$im->done;
	is($git0->qx(@log1),
		$after, 'no git history made with idempotent remove');
	eval { $im->done };
	ok(!$@, '->done is idempotent');
}

{
	ok($im->add($mime), 'add message to be purged');
	local $SIG{__WARN__} = sub {};
	ok(my $cmt = $im->purge($mime), 'purged message');
	like($cmt->[0], qr/\A[a-f0-9]{40,}\z/, 'purge returned current commit');
	$im->done;

	# again
	is($im->purge($mime), undef, 'no-op returns undef');
}

{
	my $x = 'x'x250;
	my $y = 'y'x250;
	local $SIG{__WARN__} = sub {};
	$mime->header_set('Subject', 'long mid');
	$mime->header_set('Message-ID', "<$x>");
	ok($im->add($mime), 'add excessively long Message-ID');

	$mime->header_set('Message-ID', "<$y>");
	$mime->header_set('References', "<$x>");
	ok($im->add($mime), 'add excessively long References');
	$im->done;

	my $msgs = $ibx->over->get_thread('x'x244);
	is(2, scalar(@$msgs), 'got both messages');
	is($msgs->[0]->{mid}, 'x'x244, 'stored truncated mid');
	is($msgs->[1]->{references}, '<'.('x'x244).'>', 'stored truncated ref');
	is($msgs->[1]->{mid}, 'y'x244, 'stored truncated mid(2)');
}

my $tmp = {
	inboxdir => "$inboxdir/non-existent/subdir",
	name => 'nope',
	version => 2,
	-primary_address => 'test@example.com',
};
eval {
	my $nope = PublicInbox::V2Writable->new($tmp);
	$nope->add($mime);
};
ok($@, 'V2Writable fails on non-existent dir');

{
	my $v2w = PublicInbox::V2Writable->new($tmp, 1);
	ok($v2w, 'creat flag works');
	$v2w->{parallel} = 0;
	$v2w->init_inbox(0);
	my $alt = "$tmp->{inboxdir}/all.git/objects/info/alternates";
	open my $fh, '>>', $alt or die $!;
	print $fh "$inboxdir/all.git/objects\n" or die $!;
	chmod(0664, $fh) or die "fchmod: $!";
	close $fh or die $!;
	open $fh, '<', $alt or die $!;
	my $before = do { local $/; <$fh> };

	ok($v2w->{mg}->add_epoch(3), 'init a new epoch');
	open $fh, '<', $alt or die $!;
	my $after = do { local $/; <$fh> };
	ok(index($after, $before) > 0,
		'old contents preserved after adding epoch');
	like($after, qr!\A[^\n]+?/3\.git/objects\n!s,
		'first line is newest epoch');
	my $mode = (stat($alt))[2] & 07777;
	is($mode, 0664, sprintf('0%03o', $mode).' is 0664');
}

done_testing();
