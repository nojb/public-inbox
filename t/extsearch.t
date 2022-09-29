#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use PublicInbox::InboxWritable;
use Fcntl qw(:seek);
require_git(2.6);
require_mods(qw(json DBD::SQLite Search::Xapian));
require PublicInbox::Search;
use_ok 'PublicInbox::ExtSearch';
use_ok 'PublicInbox::ExtSearchIdx';
use_ok 'PublicInbox::OverIdx';
my ($home, $for_destroy) = tmpdir();
local $ENV{HOME} = $home;
mkdir "$home/.public-inbox" or BAIL_OUT $!;
my $cfg_path = "$home/.public-inbox/config";
open my $fh, '>', $cfg_path or BAIL_OUT $!;
print $fh <<EOF or BAIL_OUT $!;
[publicinboxMda]
	spamcheck = none
EOF
close $fh or BAIL_OUT $!;
my $v2addr = 'v2test@example.com';
my $v1addr = 'v1test@example.com';
ok(run_script([qw(-init -Lbasic -V2 v2test --newsgroup v2.example),
	"$home/v2test", 'http://example.com/v2test', $v2addr ]), 'v2test init');
my $env = { ORIGINAL_RECIPIENT => $v2addr };
my $eml = eml_load('t/utf8.eml');

$eml->header_set('List-Id', '<v2.example.com>');
open($fh, '+>', undef) or BAIL_OUT $!;
$fh->autoflush(1);
print $fh $eml->as_string or BAIL_OUT $!;
seek($fh, 0, SEEK_SET) or BAIL_OUT $!;

run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or BAIL_OUT '-mda';

ok(run_script([qw(-init -V1 v1test --newsgroup v1.example), "$home/v1test",
	'http://example.com/v1test', $v1addr ]), 'v1test init');

$eml->header_set('List-Id', '<v1.example.com>');
seek($fh, 0, SEEK_SET) or BAIL_OUT $!;
truncate($fh, 0) or BAIL_OUT $!;
print $fh $eml->as_string or BAIL_OUT $!;
seek($fh, 0, SEEK_SET) or BAIL_OUT $!;

$env = { ORIGINAL_RECIPIENT => $v1addr };
run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or BAIL_OUT '-mda';

run_script([qw(-index -Lbasic), "$home/v1test"]) or BAIL_OUT "index $?";

ok(run_script([qw(-extindex --dangerous --all), "$home/extindex"]),
	'extindex init');
{
	my $es = PublicInbox::ExtSearch->new("$home/extindex");
	ok($es->has_threadid, '->has_threadid');
}

if ('with boost') {
	xsys([qw(git config publicinbox.v1test.boost), 10],
		{ GIT_CONFIG => $cfg_path });
	ok(run_script([qw(-extindex --all), "$home/extindex-b"]),
		'extindex init with boost');
	my $es = PublicInbox::ExtSearch->new("$home/extindex-b");
	my $smsg = $es->over->get_art(1);
	ok($smsg, 'got first article');
	my $xref3 = $es->over->get_xref3($smsg->{num});
	my @v1 = grep(/\Av1/, @$xref3);
	my @v2 = grep(/\Av2/, @$xref3);
	like($v1[0], qr/\Av1\.example.*?\b\Q$smsg->{blob}\E\b/,
		'smsg->{blob} respected boost');
	is(scalar(@$xref3), 2, 'only to entries');
	undef $es;

	xsys([qw(git config publicinbox.v2test.boost), 20],
		{ GIT_CONFIG => $cfg_path });
	ok(run_script([qw(-extindex --all --reindex), "$home/extindex-b"]),
		'extindex --reindex with altered boost');

	$es = PublicInbox::ExtSearch->new("$home/extindex-b");
	$smsg = $es->over->get_art(1);
	like($v2[0], qr/\Av2\.example.*?\b\Q$smsg->{blob}\E\b/,
			'smsg->{blob} respects boost after reindex');

	# high boost added later
	my $b2 = "$home/extindex-bb";
	ok(run_script([qw(-extindex), $b2, "$home/v1test"]),
		'extindex with low boost inbox only');
	ok(run_script([qw(-extindex), $b2, "$home/v2test"]),
		'extindex with high boost inbox only');
	$es = PublicInbox::ExtSearch->new($b2);
	$smsg = $es->over->get_art(1);
	$xref3 = $es->over->get_xref3($smsg->{num});
	like($v2[0], qr/\Av2\.example.*?\b\Q$smsg->{blob}\E\b/,
		'smsg->{blob} respected boost across 2 index runs');

	xsys([qw(git config --unset publicinbox.v1test.boost)],
		{ GIT_CONFIG => $cfg_path });
	xsys([qw(git config --unset publicinbox.v2test.boost)],
		{ GIT_CONFIG => $cfg_path });
}

{ # TODO: -extindex should write this to config
	open $fh, '>>', $cfg_path or BAIL_OUT $!;
	print $fh <<EOF or BAIL_OUT $!;
; for ->ALL
[extindex "all"]
	topdir = $home/extindex
EOF
	close $fh or BAIL_OUT $!;

	my $pi_cfg = PublicInbox::Config->new;
	$pi_cfg->fill_all;
	ok($pi_cfg->ALL, '->ALL');
	my $ibx = $pi_cfg->{-by_newsgroup}->{'v2.example'};
	my $ret = $pi_cfg->ALL->nntp_xref_for($ibx, $ibx->over->get_art(1));
	is_deeply($ret, { 'v1.example' => 1, 'v2.example' => 1 },
		'->nntp_xref_for');
}

SKIP: {
	require_mods(qw(Net::NNTP), 1);
	my $sock = tcp_server();
	my $host_port = tcp_host_port($sock);
	my ($out, $err) = ("$home/nntpd.out.log", "$home/nntpd.err.log");
	my $cmd = [ '-nntpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	my $td = start_script($cmd, undef, { 3 => $sock });
	my $n = Net::NNTP->new($host_port);
	my @xp = $n->xpath('<testmessage@example.com>');
	is_deeply(\@xp, [ qw(v1.example/1 v2.example/1) ]);
	$n->group('v1.example');
	my $res = $n->head(1);
	@$res = grep(/^Xref: /, @$res);
	like($res->[0], qr/ v1\.example:1 v2\.example:1/, 'nntp_xref works');
}

my $es = PublicInbox::ExtSearch->new("$home/extindex");
{
	my $smsg = $es->over->get_art(1);
	ok($smsg, 'got first article');
	is($es->over->get_art(2), undef, 'only one added');
	my $xref3 = $es->over->get_xref3(1);
	like($xref3->[0], qr/\A\Qv2.example\E:1:/, 'order preserved 1');
	like($xref3->[1], qr/\A\Qv1.example\E:1:/, 'order preserved 2');
	is(scalar(@$xref3), 2, 'only to entries');
}

if ('inbox edited') {
	my ($in, $out, $err);
	$in = $out = $err = '';
	my $opt = { 0 => \$in, 1 => \$out, 2 => \$err };
	my $env = { MAIL_EDITOR => "$^X -i -p -e 's/test message/BEST MSG/'" };
	my $cmd = [ qw(-edit -Ft/utf8.eml), "$home/v2test" ];
	ok(run_script($cmd, $env, $opt), '-edit');
	ok(run_script([qw(-extindex --all), "$home/extindex"], undef, $opt),
		'extindex again');
	like($err, qr/discontiguous range/, 'warned about discontiguous range');
	my $msg1 = $es->over->get_art(1) or BAIL_OUT 'msg1 missing';
	my $msg2 = $es->over->get_art(2) or BAIL_OUT 'msg2 missing';
	is($msg1->{mid}, $msg2->{mid}, 'edited message indexed');
	isnt($msg1->{blob}, $msg2->{blob}, 'blobs differ');
	my $eml2 = $es->smsg_eml($msg2);
	like($eml2->body, qr/BEST MSG/, 'edited body in #2');
	unlike($eml2->body, qr/test message/, 'old body discarded in #2');
	my $eml1 = $es->smsg_eml($msg1);
	like($eml1->body, qr/test message/, 'original body in #1');
	my $x1 = $es->over->get_xref3(1);
	my $x2 = $es->over->get_xref3(2);
	is(scalar(@$x1), 1, 'original only has one xref3');
	is(scalar(@$x2), 1, 'new message has one xref3');
	isnt($x1->[0], $x2->[0], 'xref3 differs');

	my $mset = $es->mset('b:"BEST MSG"');
	is($mset->size, 1, 'new message found');
	$mset = $es->mset('b:"test message"');
	is($mset->size, 1, 'old message found');
	delete @$es{qw(git over xdb qp)}; # fork preparation

	my $pi_cfg = PublicInbox::Config->new;
	$pi_cfg->fill_all;
	is(scalar($pi_cfg->ALL->mset('s:Testing')->items), 2,
		'2 results in ->ALL');
	my $res = {};
	my $nr = 0;
	$pi_cfg->each_inbox(sub {
		$nr++;
		my ($ibx) = @_;
		local $SIG{__WARN__} = sub {}; # FIXME support --reindex
		my $mset = $ibx->isrch->mset('s:Testing');
		$res->{$ibx->eidx_key} = $ibx->isrch->mset_to_smsg($ibx, $mset);
	});
	is($nr, 2, 'two inboxes');
	my $exp = {};
	for my $v (qw(v1 v2)) {
		my $ibx = $pi_cfg->lookup_newsgroup("$v.example");
		my $smsg = $ibx->over->get_art(1);
		$smsg->psgi_cull;
		$exp->{"$v.example"} = [ $smsg ];
	}
	is_deeply($res, $exp, 'isearch limited results');
	$pi_cfg = $res = $exp = undef;

	open my $rmfh, '+>', undef or BAIL_OUT $!;
	$rmfh->autoflush(1);
	print $rmfh $eml2->as_string or BAIL_OUT $!;
	seek($rmfh, 0, SEEK_SET) or BAIL_OUT $!;
	$opt->{0} = $rmfh;
	ok(run_script([qw(-learn rm --all)], undef, $opt), '-learn rm');

	ok(run_script([qw(-extindex --all), "$home/extindex"], undef, undef),
		'extindex after rm');
	is($es->over->get_art(2), undef, 'doc #2 gone');
	$mset = $es->mset('b:"BEST MSG"');
	is($mset->size, 0, 'new message gone');
}

my $misc = $es->misc;
my @it = $misc->mset('')->items;
is(scalar(@it), 2, 'two inboxes');
like($it[0]->get_document->get_data, qr/v2test/, 'docdata matched v2');
like($it[1]->get_document->get_data, qr/v1test/, 'docdata matched v1');

my $cfg = PublicInbox::Config->new;
my $schema_version = PublicInbox::Search::SCHEMA_VERSION();
my $f = "$home/extindex/ei$schema_version/over.sqlite3";
my $oidx = PublicInbox::OverIdx->new($f);
if ('inject w/o indexing') {
	use PublicInbox::Import;
	my $v1ibx = $cfg->lookup_name('v1test');
	my $last_v1_commit = $v1ibx->mm->last_commit;
	my $v2ibx = $cfg->lookup_name('v2test');
	my $last_v2_commit = $v2ibx->mm->last_commit_xap($schema_version, 0);
	my $git0 = PublicInbox::Git->new("$v2ibx->{inboxdir}/git/0.git");
	chomp(my $cmt = $git0->qx(qw(rev-parse HEAD^0)));
	is($last_v2_commit, $cmt, 'v2 index up-to-date');

	my $v2im = PublicInbox::Import->new($git0, undef, undef, $v2ibx);
	$v2im->{lock_path} = undef;
	$v2im->{path_type} = 'v2';
	$v2im->add(eml_load('t/mda-mime.eml'));
	$v2im->done;
	chomp(my $tip = $git0->qx(qw(rev-parse HEAD^0)));
	isnt($tip, $cmt, '0.git v2 updated');

	# inject a message w/o updating index
	rename("$home/v1test/public-inbox", "$home/v1test/skip-index") or
		BAIL_OUT $!;
	open(my $eh, '<', 't/iso-2202-jp.eml') or BAIL_OUT $!;
	run_script(['-mda', '--no-precheck'], $env, { 0 => $eh}) or
		BAIL_OUT '-mda';
	rename("$home/v1test/skip-index", "$home/v1test/public-inbox") or
		BAIL_OUT $!;

	my ($in, $out, $err);
	$in = $out = $err = '';
	my $opt = { 0 => \$in, 1 => \$out, 2 => \$err };
	ok(run_script([qw(-extindex -v -v --all), "$home/extindex"],
		undef, undef), 'extindex noop');
	$es->{xdb}->reopen;
	my $mset = $es->mset('mid:199707281508.AAA24167@hoyogw.example');
	is($mset->size, 0, 'did not attempt to index unindexed v1 message');
	$mset = $es->mset('mid:multipart-html-sucks@11');
	is($mset->size, 0, 'did not attempt to index unindexed v2 message');
	ok(run_script([qw(-index --all)]), 'indexed v1 and v2 inboxes');

	isnt($v1ibx->mm->last_commit, $last_v1_commit, '-index v1 worked');
	isnt($v2ibx->mm->last_commit_xap($schema_version, 0),
		$last_v2_commit, '-index v2 worked');
	ok(run_script([qw(-extindex --all), "$home/extindex"]),
		'extindex updates');

	$es->{xdb}->reopen;
	$mset = $es->mset('mid:199707281508.AAA24167@hoyogw.example');
	is($mset->size, 1, 'got v1 message');
	$mset = $es->mset('mid:multipart-html-sucks@11');
	is($mset->size, 1, 'got v2 message');
}

if ('reindex catches missed messages') {
	my $v2ibx = $cfg->lookup_name('v2test');
	$v2ibx->{-no_fsync} = 1;
	my $im = PublicInbox::InboxWritable->new($v2ibx)->importer(0);
	my $cmt_a = $v2ibx->mm->last_commit_xap($schema_version, 0);
	my $eml = eml_load('t/data/0001.patch');
	$im->add($eml);
	$im->done;
	my $cmt_b = $v2ibx->mm->last_commit_xap($schema_version, 0);
	isnt($cmt_a, $cmt_b, 'v2 0.git HEAD updated');
	$oidx->dbh;
	my $uv = $v2ibx->uidvalidity;
	my $lc_key = "lc-v2:v2.example//$uv;0";
	is($oidx->eidx_meta($lc_key, $cmt_b), $cmt_a,
		'update lc-v2 meta, old is as expected');
	my $max = $oidx->max;
	$oidx->dbh_close;
	ok(run_script([qw(-extindex), "$home/extindex", $v2ibx->{inboxdir}]),
		'-extindex noop');
	is($oidx->max, $max, '->max unchanged');
	is($oidx->eidx_meta($lc_key), $cmt_b, 'lc-v2 unchanged');
	$oidx->dbh_close;
	my $opt = { 2 => \(my $err = '') };
	ok(run_script([qw(-extindex --reindex), "$home/extindex",
			$v2ibx->{inboxdir}], undef, $opt),
			'--reindex for unseen');
	is($oidx->max, $max + 1, '->max bumped');
	is($oidx->eidx_meta($lc_key), $cmt_b, 'lc-v2 stays unchanged');
	my @err = split(/^/, $err);
	is(scalar(@err), 1, 'only one warning') or diag "err=$err";
	like($err[0], qr/I: reindex_unseen/, 'got reindex_unseen message');
	my $new = $oidx->get_art($max + 1);
	is($new->{subject}, $eml->header('Subject'), 'new message added');

	$es->{xdb}->reopen;
	# git patch-id --stable <t/data/0001.patch | awk '{print $1}'
	my $patchid = '91ee6b761fc7f47cad9f2b09b10489f313eb5b71';
	my $mset = $es->search->mset("patchid:$patchid");
	is($mset->size, 1, 'patchid search works');

	$mset = $es->mset("mid:$new->{mid}");
	is($mset->size, 1, 'previously unseen, now indexed in Xapian');

	ok($im->remove($eml), 'remove new message from v2 inbox');
	$im->done;
	my $cmt_c = $v2ibx->mm->last_commit_xap($schema_version, 0);
	is($oidx->eidx_meta($lc_key, $cmt_c), $cmt_b,
		'bump lc-v2 meta again to skip v2 remove');
	$err = '';
	$oidx->dbh_close;
	ok(run_script([qw(-extindex --reindex), "$home/extindex",
			$v2ibx->{inboxdir}], undef, $opt),
			'--reindex for stale');
	@err = split(/^/, $err);
	is(scalar(@err), 1, 'only one warning') or diag "err=$err";
	like($err[0], qr/\(#$new->{num}\): stale/, 'got stale message warning');
	is($oidx->get_art($new->{num}), undef,
		'stale message gone from over');
	is_deeply($oidx->get_xref3($new->{num}), [],
		'stale message has no xref3');
	$es->{xdb}->reopen;
	$mset = $es->mset("mid:$new->{mid}");
	is($mset->size, 0, 'stale mid gone Xapian');

	ok(run_script([qw(-extindex --reindex --all --fast), "$home/extindex"],
			undef, $opt), '--reindex w/ --fast');
	ok(!run_script([qw(-extindex --all --fast), "$home/extindex"],
			undef, $opt), '--fast alone makes no sense');
}

if ('reindex catches content bifurcation') {
	use PublicInbox::MID qw(mids);
	my $v2ibx = $cfg->lookup_name('v2test');
	$v2ibx->{-no_fsync} = 1;
	my $im = PublicInbox::InboxWritable->new($v2ibx)->importer(0);
	my $eml = eml_load('t/data/message_embed.eml');
	my $cmt_a = $v2ibx->mm->last_commit_xap($schema_version, 0);
	$im->add($eml);
	$im->done;
	my $cmt_b = $v2ibx->mm->last_commit_xap($schema_version, 0);
	my $uv = $v2ibx->uidvalidity;
	my $lc_key = "lc-v2:v2.example//$uv;0";
	$oidx->dbh;
	is($oidx->eidx_meta($lc_key, $cmt_b), $cmt_a,
		'update lc-v2 meta, old is as expected');
	my $mid = mids($eml)->[0];
	my $smsg = $v2ibx->over->next_by_mid($mid, \(my $id), \(my $prev));
	my $oldmax = $oidx->max;
	my $x3_orig = $oidx->get_xref3(3);
	is(scalar(@$x3_orig), 1, '#3 has one xref');
	$oidx->add_xref3(3, $smsg->{num}, $smsg->{blob}, 'v2.example');
	my $x3 = $oidx->get_xref3(3);
	is(scalar(@$x3), 2, 'injected xref3');
	$oidx->commit_lazy;
	my $opt = { 2 => \(my $err = '') };
	ok(run_script([qw(-extindex --all), "$home/extindex"], undef, $opt),
		'extindex --all is noop');
	is($err, '', 'no warnings in index');
	$oidx->dbh;
	is($oidx->max, $oldmax, 'oidx->max unchanged');
	$oidx->dbh_close;
	ok(run_script([qw(-extindex --reindex --all), "$home/extindex"],
		undef, $opt), 'extindex --reindex') or diag explain($opt);
	$oidx->dbh;
	ok($oidx->max > $oldmax, 'oidx->max bumped');
	like($err, qr/split into 2 due to deduplication change/,
		'bifurcation noted');
	my $added = $oidx->get_art($oidx->max);
	is($added->{blob}, $smsg->{blob}, 'new blob indexed');
	is_deeply(["v2.example:$smsg->{num}:$smsg->{blob}"],
		$oidx->get_xref3($added->{num}),
		'xref3 corrected for bifurcated message');
	is_deeply($oidx->get_xref3(3), $x3_orig, 'xref3 restored for #3');
}

if ('--reindex --rethread') {
	my $before = $oidx->dbh->selectrow_array(<<'');
SELECT MAX(tid) FROM over WHERE num > 0

	my $opt = {};
	ok(run_script([qw(-extindex --reindex --rethread --all),
			"$home/extindex"], undef, $opt),
			'--rethread');
	my $after = $oidx->dbh->selectrow_array(<<'');
SELECT MIN(tid) FROM over WHERE num > 0

	# actual rethread logic is identical to v1/v2 and tested elsewhere
	ok($after > $before, '--rethread updates MIN(tid)');
}

if ('remove v1test and test gc') {
	xsys([qw(git config --unset publicinbox.v1test.inboxdir)],
		{ GIT_CONFIG => $cfg_path });
	my $opt = { 2 => \(my $err = '') };
	ok(run_script([qw(-extindex --gc), "$home/extindex"], undef, $opt),
		'extindex --gc');
	like($err, qr/^I: remove #1 v1\.example /ms, 'removed v1 message');
	is(scalar(grep(!/^I:/, split(/^/m, $err))), 0,
		'no non-informational messages');
	$misc->{xdb}->reopen;
	@it = $misc->mset('')->items;
	is(scalar(@it), 1, 'only one inbox left');
}

if ('dedupe + dry-run') {
	my @cmd = ('-extindex', "$home/extindex");
	my $opt = { 2 => \(my $err = '') };
	ok(run_script([@cmd, '--dedupe'], undef, $opt), '--dedupe');
	ok(run_script([@cmd, qw(--dedupe --dry-run)], undef, $opt),
		'--dry-run --dedupe');
	is $err, '', 'no errors';
	ok(!run_script([@cmd, qw(--dry-run)], undef, $opt),
		'--dry-run alone fails');
}

# chmod 0755, $home or xbail "chmod: $!";
for my $j (1, 3, 6) {
	my $o = { 2 => \(my $err = '') };
	my $d = "$home/extindex-j$j";
	ok(run_script(['-extindex', "-j$j", '--all', $d], undef, $o),
		"init with -j$j");
	my $max = $j - 2;
	$max = 0 if $max < 0;
	my @dirs = glob("$d/ei*/?");
	like($dirs[-1], qr!/ei[0-9]+/$max\z!, '-j works');
}

SKIP: {
	my $d = "$home/extindex-j1";
	my $es = PublicInbox::ExtSearch->new($d);
	ok(my $nresult0 = $es->mset('z:0..')->size, 'got results');
	ok(ref($es->{xdb}), '{xdb} created');
	my $nshards1 = $es->{nshard};
	is($nshards1, 1, 'correct shard count');

	my @ei_dir = glob("$d/ei*/");
	chmod 0755, $ei_dir[0] or xbail "chmod: $!";
	my $mode = sprintf('%04o', 07777 & (stat($ei_dir[0]))[2]);
	is($mode, '0755', 'mode set on ei*/ dir');
	my $o = { 2 => \(my $err = '') };
	ok(run_script([qw(-xcpdb -R4), $d]), 'xcpdb R4');
	my @dirs = glob("$d/ei*/?");
	for my $i (0..3) {
		is(grep(m!/ei[0-9]+/$i\z!, @dirs), 1, "shard [$i] created");
		my $m = sprintf('%04o', 07777 & (stat($dirs[$i]))[2]);
		is($m, $mode, "shard [$i] mode");
	}
	delete @$es{qw(xdb qp)};
	is($es->mset('z:0..')->size, $nresult0, 'new shards, same results');

	for my $i (4..5) {
		is(grep(m!/ei[0-9]+/$i\z!, @dirs), 0, "no shard [$i]");
	}

	ok(run_script([qw(-xcpdb -R2), $d]), 'xcpdb -R2');
	@dirs = glob("$d/ei*/?");
	for my $i (0..1) {
		is(grep(m!/ei[0-9]+/$i\z!, @dirs), 1, "shard [$i] kept");
	}
	for my $i (2..3) {
		is(grep(m!/ei[0-9]+/$i\z!, @dirs), 0, "no shard [$i]");
	}
	skip 'xapian-compact missing', 4 unless have_xapian_compact;
	ok(run_script([qw(-compact), $d], undef, $o), 'compact');
	# n.b. stderr contains xapian-compact output

	my @d2 = glob("$d/ei*/?");
	is_deeply(\@d2, \@dirs, 'dirs consistent after compact');
	ok(run_script([qw(-extindex --dedupe --all), $d]),
		'--dedupe works after compact');
	ok(run_script([qw(-extindex --gc), $d], undef, $o),
		'--gc works after compact');
}

{ # ensure --gc removes non-xposted messages
	my $old_size = -s $cfg_path // xbail "stat $cfg_path $!";
	my $tmp_addr = 'v2tmp@example.com';
	run_script([qw(-init v2tmp --indexlevel basic
		--newsgroup v2tmp.example),
		"$home/v2tmp", 'http://example.com/v2tmp', $tmp_addr ])
		or xbail '-init';
	$env = { ORIGINAL_RECIPIENT => $tmp_addr };
	open $fh, '+>', undef or xbail "open $!";
	$fh->autoflush(1);
	my $mid = 'tmpmsg@example.com';
	print $fh <<EOM or xbail "print $!";
From: b\@z
To: b\@r
Message-Id: <$mid>
Subject: tmpmsg
Date: Tue, 19 Jan 2038 03:14:07 +0000

EOM
	seek $fh, 0, SEEK_SET or xbail "seek $!";
	run_script([qw(-mda --no-precheck)], $env, {0 => $fh}) or xbail '-mda';
	ok(run_script([qw(-extindex --all), "$home/extindex"]), 'update');
	my $nr;
	{
		my $es = PublicInbox::ExtSearch->new("$home/extindex");
		my ($id, $prv);
		my $smsg = $es->over->next_by_mid($mid, \$id, \$prv);
		ok($smsg, 'tmpmsg indexed');
		my $mset = $es->search->mset("mid:$mid");
		is($mset->size, 1, 'new message found');
		$mset = $es->search->mset('z:0..');
		$nr = $mset->size;
	}
	truncate($cfg_path, $old_size) or xbail "truncate $!";
	my $rdr = { 2 => \(my $err) };
	ok(run_script([qw(-extindex --gc), "$home/extindex"], undef, $rdr),
		'gc to get rid of removed inbox');
	is_deeply([ grep(!/^(?:I:|#)/, split(/^/m, $err)) ], [],
		'no non-informational errors in stderr');

	my $es = PublicInbox::ExtSearch->new("$home/extindex");
	my $mset = $es->search->mset("mid:$mid");
	is($mset->size, 0, 'tmpmsg gone from search');
	my ($id, $prv);
	is($es->over->next_by_mid($mid, \$id, \$prv), undef,
		'tmpmsg gone from over');
	$id = $prv = undef;
	is($es->over->next_by_mid('testmessage@example.com', \$id, \$prv),
		undef, 'remaining message not indavderover');
	$mset = $es->search->mset('z:0..');
	is($mset->size, $nr - 1, 'existing messages not clobbered from search');
	my $o = $es->over->{dbh}->selectall_arrayref(<<EOM);
SELECT num FROM over ORDER BY num
EOM
	is(scalar(@$o), $mset->size, 'over row count matches Xapian');
	my $x = $es->over->{dbh}->selectall_arrayref(<<EOM);
SELECT DISTINCT(docid) FROM xref3 ORDER BY docid
EOM
	is_deeply($x, $o, 'xref3 and over docids match');
}

done_testing;
