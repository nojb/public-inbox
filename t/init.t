# Copyright (C) 2014-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use PublicInbox::TestCommon;
use PublicInbox::Admin;
use File::Basename;
my ($tmpdir, $for_destroy) = tmpdir();
sub quiet_fail {
	my ($cmd, $msg) = @_;
	my $err = '';
	ok(!run_script($cmd, undef, { 2 => \$err, 1 => \$err }), $msg);
}

{
	local $ENV{PI_DIR} = "$tmpdir/.public-inbox/";
	my $cfgfile = "$ENV{PI_DIR}/config";
	my $cmd = [ '-init', 'blist', "$tmpdir/blist",
		   qw(http://example.com/blist blist@example.com) ];
	ok(run_script($cmd), 'public-inbox-init OK');

	is(read_indexlevel('blist'), '', 'indexlevel unset by default');

	ok(-e $cfgfile, "config exists, now");
	ok(run_script($cmd), 'public-inbox-init OK (idempotent)');

	chmod 0666, $cfgfile or die "chmod failed: $!";
	$cmd = [ '-init', 'clist', "$tmpdir/clist",
		   qw(http://example.com/clist clist@example.com)];
	ok(run_script($cmd), 'public-inbox-init clist OK');
	is((stat($cfgfile))[2] & 07777, 0666, "permissions preserved");

	$cmd = [ '-init', 'clist', '-V2', "$tmpdir/clist",
		   qw(http://example.com/clist clist@example.com) ];
	quiet_fail($cmd, 'attempting to init V2 from V1 fails');
	ok(!-e "$cfgfile.lock", 'no lock leftover after init');

	open my $lock, '+>', "$cfgfile.lock" or die;
	$cmd = [ '-init', 'lock', "$tmpdir/lock",
		qw(http://example.com/lock lock@example.com) ];
	ok(-e "$cfgfile.lock", 'lock exists');

	# this calls exit():
	my $err = '';
	ok(!run_script($cmd, undef, {2 => \$err}), 'lock init failed');
	is($? >> 8, 255, 'got expected exit code on lock failure');
	ok(unlink("$cfgfile.lock"),
		'-init did not unlink lock on failure');
}
{
	my $rdr = { 2 => \(my $err = '') };
	my $cmd = [ '-init', 'alist', "$tmpdir/a\nlist",
		   qw(http://example.com/alist alist@example.com) ];
	ok(!run_script($cmd, undef, $rdr),
		'public-inbox-init rejects LF in inboxdir');
	like($err, qr/`\\n' not allowed in `/s, 'reported \\n');
}

SKIP: {
	require_mods(qw(DBD::SQLite Search::Xapian::WritableDatabase), 2);
	require_git(2.6, 1) or skip "git 2.6+ required", 2;
	use_ok 'PublicInbox::Msgmap';
	local $ENV{PI_DIR} = "$tmpdir/.public-inbox/";
	my $cfgfile = "$ENV{PI_DIR}/config";
	my $cmd = [ '-init', '-V2', 'v2list', "$tmpdir/v2list",
		   qw(http://example.com/v2list v2list@example.com) ];
	ok(run_script($cmd), 'public-inbox-init -V2 OK');
	ok(-d "$tmpdir/v2list", 'v2list directory exists');
	ok(-f "$tmpdir/v2list/msgmap.sqlite3", 'msgmap exists');
	ok(-d "$tmpdir/v2list/all.git", 'catch-all.git directory exists');
	$cmd = [ '-init', 'v2list', "$tmpdir/v2list",
		   qw(http://example.com/v2list v2list@example.com) ];
	ok(run_script($cmd), 'public-inbox-init is idempotent');
	ok(! -d "$tmpdir/public-inbox" && !-d "$tmpdir/objects",
		'idempotent invocation w/o -V2 does not make inbox v1');
	is(read_indexlevel('v2list'), '', 'indexlevel unset by default');

	$cmd = [ '-init', 'v2list', "-V1", "$tmpdir/v2list",
		   qw(http://example.com/v2list v2list@example.com) ];
	quiet_fail($cmd, 'initializing V2 as V1 fails');

	foreach my $lvl (qw(medium basic)) {
		my $dir = "$tmpdir/v2$lvl";
		$cmd = [ '-init', "v2$lvl", '-V2', '-L', $lvl,
			$dir, "http://example.com/v2$lvl",
			"v2$lvl\@example.com" ];
		ok(run_script($cmd), "-init -L $lvl");
		is(read_indexlevel("v2$lvl"), $lvl, "indexlevel set to '$lvl'");
		my $ibx = PublicInbox::Inbox->new({ inboxdir => $dir });
		is(PublicInbox::Admin::detect_indexlevel($ibx), $lvl,
			'detected expected level w/o config');
	}

	# loop for idempotency
	for (1..2) {
		$cmd = [ '-init', '-V2', '-S1', 'skip1', "$tmpdir/skip1",
			   qw(http://example.com/skip1 skip1@example.com) ];
		ok(run_script($cmd), "--skip-epoch 1");
		my $gits = [ glob("$tmpdir/skip1/git/*.git") ];
		is_deeply($gits, ["$tmpdir/skip1/git/1.git"], 'skip OK');
	}

	$cmd = [ '-init', '-V2', '--skip-epoch=2', 'skip2', "$tmpdir/skip2",
		   qw(http://example.com/skip2 skip2@example.com) ];
	ok(run_script($cmd), "--skip-epoch 2");
	my $gits = [ glob("$tmpdir/skip2/git/*.git") ];
	is_deeply($gits, ["$tmpdir/skip2/git/2.git"], 'skipping 2 works, too');

	xsys(qw(git config), "--file=$ENV{PI_DIR}/config",
			'publicinboxmda.spamcheck', 'none') == 0 or
			BAIL_OUT "git config $?";
	my $addr = 'skip3@example.com';
	$cmd = [ qw(-init -V2 -Lbasic -N12 skip3), "$tmpdir/skip3",
		   qw(http://example.com/skip3), $addr ];
	ok(run_script($cmd), '--skip-artnum -V2');
	my $env = { ORIGINAL_RECIPIENT => $addr };
	my $mid = 'skip-artnum@example.com';
	my $msg = "Message-ID: <$mid>\n\n";
	my $rdr = { 0 => \$msg, 2 => \(my $err = '')  };
	ok(run_script([qw(-mda --no-precheck)], $env, $rdr), 'deliver V1');
	my $mm = PublicInbox::Msgmap->new_file("$tmpdir/skip3/msgmap.sqlite3");
	my $n = $mm->num_for($mid);
	is($n, 13, 'V2 NNTP article numbers skipped via --skip-artnum');

	$addr = 'skip4@example.com';
	$env = { ORIGINAL_RECIPIENT => $addr };
	$cmd = [ qw(-init -V1 -N12 -Lmedium skip4), "$tmpdir/skip4",
		   qw(http://example.com/skip4), $addr ];
	ok(run_script($cmd), '--skip-artnum -V1');
	ok(run_script([qw(-mda --no-precheck)], $env, $rdr), 'deliver V1');
	$mm = PublicInbox::Msgmap->new("$tmpdir/skip4");
	$n = $mm->num_for($mid);
	is($n, 13, 'V1 NNTP article numbers skipped via --skip-artnum');
}

done_testing();

sub read_indexlevel {
	my ($inbox) = @_;
	my $cmd = [ qw(git config), "publicinbox.$inbox.indexlevel" ];
	my $env = { GIT_CONFIG => "$ENV{PI_DIR}/config" };
	chomp(my $lvl = xqx($cmd, $env));
	$lvl;
}
