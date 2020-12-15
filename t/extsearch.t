#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use PublicInbox::Search;
use Fcntl qw(:seek);
my $json = PublicInbox::Config::json() or plan skip_all => 'JSON missing';
require_git(2.6);
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::ExtSearch';
use_ok 'PublicInbox::ExtSearchIdx';
my $sock = tcp_server();
my $host_port = $sock->sockhost . ':' . $sock->sockport;
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

ok(run_script([qw(-extindex --all), "$home/extindex"]), 'extindex init');
{
	my $es = PublicInbox::ExtSearch->new("$home/extindex");
	ok($es->has_threadid, '->has_threadid');
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
	delete @$es{qw(git over xdb)}; # fork preparation

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
	use PublicInbox::InboxWritable;
	use PublicInbox::OverIdx;
	my $v2ibx = $cfg->lookup_name('v2test');
	my $im = PublicInbox::InboxWritable->new($v2ibx)->importer(0);
	my $cmt_a = $v2ibx->mm->last_commit_xap($schema_version, 0);
	my $eml = eml_load('t/data/0001.patch');
	$im->add($eml);
	$im->done;
	my $cmt_b = $v2ibx->mm->last_commit_xap($schema_version, 0);
	isnt($cmt_a, $cmt_b, 'v2 0.git HEAD updated');
	my $f = "$home/extindex/ei$schema_version/over.sqlite3";
	my $oidx = PublicInbox::OverIdx->new($f);
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
	is(scalar(@err), 1, 'only one warning');
	like($err[0], qr/I: reindex_unseen/, 'got reindex_unseen message');
	my $new = $oidx->get_art($max + 1);
	is($new->{subject}, $eml->header('Subject'), 'new message added');

	$es->{xdb}->reopen;
	my $mset = $es->mset("mid:$new->{mid}");
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
	is(scalar(@err), 1, 'only one warning');
	like($err[0], qr/\(#$new->{num}\): stale/, 'got stale message warning');
	is($oidx->get_art($new->{num}), undef,
		'stale message gone from over');
	is_deeply($oidx->get_xref3($new->{num}), [],
		'stale message has no xref3');
	$es->{xdb}->reopen;
	$mset = $es->mset("mid:$new->{mid}");
	is($mset->size, 0, 'stale mid gone Xapian');
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

done_testing;
