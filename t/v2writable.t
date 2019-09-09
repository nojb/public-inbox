# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::ContentId qw(content_digest);
use File::Temp qw/tempdir/;
require './t/common.perl';
require_git(2.6);
foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for nntpd.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
umask 007;
my $mainrepo = tempdir('pi-v2writable-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => $mainrepo,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		'Message-ID' => '<a-mid@b>',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);

my $im = PublicInbox::V2Writable->new($ibx, {nproc => 1});
is($im->{shards}, 1, 'one shard when forced');
ok($im->add($mime), 'ordinary message added');
foreach my $f ("$mainrepo/msgmap.sqlite3",
		glob("$mainrepo/xap*/*"),
		glob("$mainrepo/xap*/*/*")) {
	my @st = stat($f);
	my ($bn) = (split(m!/!, $f))[-1];
	is($st[2] & 07777, -f _ ? 0660 : 0770,
		"default sharedRepository respected for $bn");
}

my $git0;

if ('ensure git configs are correct') {
	my @cmd = (qw(git config), "--file=$mainrepo/all.git/config",
		qw(core.sharedRepository 0644));
	is(system(@cmd), 0, "set sharedRepository in all.git");
	$git0 = PublicInbox::Git->new("$mainrepo/git/0.git");
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
	my $sec = PublicInbox::MIME->new($mime->as_string);
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
	my $fake = PublicInbox::MIME->new($mime->as_string);
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
}

{
	$mime->header_set('Message-Id', '<abcde@1>', '<abcde@2>');
	$mime->header_set('References', '<zz-mid@b>');
	ok($im->add($mime), 'message with multiple Message-ID');
	$im->done;
	my ($total, undef) = $ibx->over->recent;
	is($ibx->mm->num_highwater, $total, 'got expected highwater value');
	my $srch = $ibx->search;
	my $mset1 = $srch->reopen->query('m:abcde@1', { mset => 1 });
	is($mset1->size, 1, 'message found by first MID');
	my $mset2 = $srch->reopen->query('m:abcde@2', { mset => 1 });
	is($mset2->size, 1, 'message found by second MID');
	is((($mset1->items)[0])->get_docid, (($mset2->items)[0])->get_docid,
		'same document') if ($mset1->size);
}

{
	use Net::NNTP;
	my $err = "$mainrepo/stderr.log";
	my $out = "$mainrepo/stdout.log";
	my $group = 'inbox.comp.test.v2writable';
	my $pi_config = "$mainrepo/pi_config";
	open my $fh, '>', $pi_config or die "open: $!\n";
	print $fh <<EOF
[publicinbox "test-v2writable"]
	mainrepo = $mainrepo
	version = 2
	address = test\@example.com
	newsgroup = $group
EOF
	;
	close $fh or die "close: $!\n";
	my $sock = tcp_server();
	ok($sock, 'sock created');
	my $pid;
	my $len;
	END { kill 'TERM', $pid if defined $pid };
	my $nntpd = 'blib/script/public-inbox-nntpd';
	my $cmd = [ $nntpd, "--stdout=$out", "--stderr=$err" ];
	$pid = spawn_listener({ PI_CONFIG => $pi_config }, $cmd, [ $sock ]);
	my $host_port = $sock->sockhost . ':' . $sock->sockport;
	my $n = Net::NNTP->new($host_port);
	$n->group($group);
	my $x = $n->xover('1-');
	my %uniq;
	foreach my $num (sort { $a <=> $b } keys %$x) {
		my $mid = $x->{$num}->[3];
		is($uniq{$mid}++, 0, "MID for $num is unique in XOVER");
		is_deeply($n->xhdr('Message-ID', $num),
			 { $num => $mid }, "XHDR lookup OK on num $num");
		is_deeply($n->xhdr('Message-ID', $mid),
			 { $mid => $mid }, "XHDR lookup OK on MID $num");
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
	my $smsg = $im->remove($mime, 'test removal');
	$im->done;
	my @after = $git0->qx(@log, qw(--pretty=oneline));
	my $tip = shift @after;
	like($tip, qr/\A[a-f0-9]+ test removal\n\z/s,
		'commit message propagated to git');
	is_deeply(\@after, \@before, 'only one commit written to git');
	is($ibx->mm->num_for($smsg->mid), undef, 'no longer in Msgmap by mid');
	my $num = $smsg->{num};
	like($num, qr/\A\d+\z/, 'numeric number in return message');
	is($ibx->mm->mid_for($num), undef, 'no longer in Msgmap by num');
	my $srch = $ibx->search->reopen;
	my $mset = $srch->query('m:'.$smsg->mid, { mset => 1});
	is($mset->size, 0, 'no longer found in Xapian');
	my @log1 = (@log, qw(-1 --pretty=raw --raw -r --no-renames));
	is($srch->{over_ro}->get_art($num), undef,
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
	ok(my $cmts = $im->purge($mime), 'purged message');
	like($cmts->[0], qr/\A[a-f0-9]{40}\z/, 'purge returned current commit');
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
	$im->barrier;

	my $msgs = $ibx->search->{over_ro}->get_thread('x'x244);
	is(2, scalar(@$msgs), 'got both messages');
	is($msgs->[0]->{mid}, 'x'x244, 'stored truncated mid');
	is($msgs->[1]->{references}, '<'.('x'x244).'>', 'stored truncated ref');
	is($msgs->[1]->{mid}, 'y'x244, 'stored truncated mid(2)');
	$im->done;
}

done_testing();
