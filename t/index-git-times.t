# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Import;
use PublicInbox::Config;
use PublicInbox::Admin;
use File::Path qw(remove_tree);

require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::Over';

my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{PI_CONFIG} = "$tmpdir/cfg";
my $v1dir = "$tmpdir/v1";
my $addr = 'x@example.com';
run_script(['-init', '--indexlevel=medium', 'v1', $v1dir,
		'http://example.com/x', $addr])
	or die "init failed";

{
	my $data = <<'EOF';
blob
mark :1
data 133
From: timeless <t@example.com>
To: x <x@example.com>
Subject: can I haz the time?
Message-ID: <19700101000000-1234@example.com>

plz

reset refs/heads/master
commit refs/heads/master
mark :2
author timeless <t@example.com> 749520000 +0100
committer x <x@example.com> 1285977600 -0100
data 20
can I haz the time?
M 100644 :1 53/256f6177504c2878d3a302ef5090dacf5e752c

EOF
	pipe(my($r, $w)) or die;
	length($data) <= 512 or die "data too large to fit in POSIX pipe";
	print $w $data or die;
	close $w or die;
	my $cmd = ['git', "--git-dir=$v1dir", 'fast-import', '--quiet'];
	PublicInbox::Import::run_die($cmd, undef, { 0 => $r });
}

run_script(['-index', '--skip-docdata', $v1dir]) or die 'v1 index failed';

my $smsg;
{
	my $cfg = PublicInbox::Config->new;
	my $ibx = $cfg->lookup($addr);
	my $lvl = PublicInbox::Admin::detect_indexlevel($ibx);
	is($lvl, 'medium', 'indexlevel detected');
	is($ibx->{-skip_docdata}, 1, '--skip-docdata flag set on -index');
	$smsg = $ibx->over->get_art(1);
	is($smsg->{ds}, 749520000, 'datestamp from git author time');
	is($smsg->{ts}, 1285977600, 'timestamp from git committer time');
	my $res = $ibx->search->query("m:$smsg->{mid}");
	is(scalar @$res, 1, 'got one result for m:');
	is($res->[0]->{ds}, $smsg->{ds}, 'Xapian stored datestamp');
	$res = $ibx->search->query('d:19931002..19931002');
	is(scalar @$res, 1, 'got one result for d:');
	is($res->[0]->{ds}, $smsg->{ds}, 'Xapian search on datestamp');
}
SKIP: {
	require_git(2.6, 1) or skip('git 2.6+ required for v2', 10);
	my $v2dir = "$tmpdir/v2";
	run_script(['-convert', $v1dir, $v2dir]) or die 'v2 conversion failed';

	my $check_v2 = sub {
		my $ibx = PublicInbox::Inbox->new({inboxdir => $v2dir,
				address => $addr});
		my $lvl = PublicInbox::Admin::detect_indexlevel($ibx);
		is($lvl, 'medium', 'indexlevel detected after convert');
		is($ibx->{-skip_docdata}, 1,
			'--skip-docdata preserved after convert');
		my $v2smsg = $ibx->over->get_art(1);
		is($v2smsg->{ds}, $smsg->{ds},
			'v2 datestamp from git author time');
		is($v2smsg->{ts}, $smsg->{ts},
			'v2 timestamp from git committer time');
		my $res = $ibx->search->query("m:$smsg->{mid}");
		is($res->[0]->{ds}, $smsg->{ds}, 'Xapian stored datestamp');
		$res = $ibx->search->query('d:19931002..19931002');
		is(scalar @$res, 1, 'got one result for d:');
		is($res->[0]->{ds}, $smsg->{ds}, 'Xapian search on datestamp');
	};
	$check_v2->();
	remove_tree($v2dir);

	# test non-parallelized conversion
	run_script(['-convert', '-j0', $v1dir, $v2dir]) or
		die 'v2 conversion failed';
	$check_v2->();
}

done_testing;
