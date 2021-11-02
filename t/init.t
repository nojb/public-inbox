# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use PublicInbox::TestCommon;
use PublicInbox::Admin;
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

	my @init_args = ('i', "$tmpdir/i",
		   qw(http://example.com/i i@example.com));
	$cmd = [ qw(-init -c .bogus=val), @init_args ];
	quiet_fail($cmd, 'invalid -c KEY=VALUE fails');
	$cmd = [ qw(-init -c .bogus=val), @init_args ];
	quiet_fail($cmd, '-c KEY-only fails');
	$cmd = [ qw(-init -c address=clist@example.com), @init_args ];
	quiet_fail($cmd, '-c address=CONFLICTING-VALUE fails');

	$cmd = [ qw(-init -c no=problem -c no=problemo), @init_args ];
	ok(run_script($cmd), '-c KEY=VALUE runs');
	my $env = { GIT_CONFIG => "$ENV{PI_DIR}/config" };
	chomp(my @v = xqx([qw(git config --get-all publicinbox.i.no)], $env));
	is_deeply(\@v, [ qw(problem problemo) ]) or xbail(\@v);

	ok(run_script($cmd), '-c KEY=VALUE runs idempotently');
	chomp(my @v2 = xqx([qw(git config --get-all publicinbox.i.no)], $env));
	is_deeply(\@v, \@v2, 'nothing repeated') or xbail(\@v2);

	ok(run_script([@$cmd, '-c', 'no=more']), '-c KEY=VALUE addendum');
	chomp(@v = xqx([qw(git config --get-all publicinbox.i.no)], $env));
	is_deeply(\@v, [ qw(problem problemo more) ]) or xbail(\@v);


	ok(run_script([@$cmd, '-c', 'no=problem']), '-c KEY=VALUE repeated');
	chomp(@v = xqx([qw(git config --get-all publicinbox.i.no)], $env));
	is_deeply(\@v, [ qw(problem problemo more) ]) or xbail(\@v);

	ok(run_script([@$cmd, '-c', 'address=j@example.com']),
		'-c KEY=VALUE address');
	chomp(@v = xqx([qw(git config --get-all publicinbox.i.address)], $env));
	is_deeply(\@v, [ qw(i@example.com j@example.com) ],
		'extra address added via -c KEY=VALUE');
}
{
	my $env = { PI_DIR => "$tmpdir/.public-inbox/" };
	my $rdr = { 2 => \(my $err = '') };
	my $cmd = [ '-init', 'alist', "$tmpdir/a\nlist",
		   qw(http://example.com/alist alist@example.com) ];
	ok(!run_script($cmd, $env, $rdr),
		'public-inbox-init rejects LF in inboxdir');
	like($err, qr/`\\n' not allowed in `/s, 'reported \\n');
	is_deeply([glob("$tmpdir/.public-inbox/pi-init-*")], [],
		'no junk files left behind');

	# "git init" does this, too
	$cmd = [ '-init', 'deep-non-existent', "$tmpdir/a/b/c/d",
		   qw(http://example.com/abcd abcd@example.com) ];
	$err = '';
	my $umask = umask(022) // xbail "umask: $!";
	ok(run_script($cmd, $env, $rdr), 'initializes non-existent hierarchy');
	umask($umask) // xbail "umask: $!";
	ok(-d "$tmpdir/a/b/c/d", 'directory created');
	my $desc = "$tmpdir/a/b/c/d/description";
	is(PublicInbox::Inbox::try_cat($desc),
		"public inbox for abcd\@example.com\n", 'description set');
	my $mode = (stat($desc))[2];
	is(sprintf('0%03o', $mode & 0777), '0644',
		'description respects umask');

	open my $fh, '>', "$tmpdir/d" or BAIL_OUT "open: $!";
	close $fh;
	$cmd = [ '-init', 'd-f-conflict', "$tmpdir/d/f/conflict",
		   qw(http://example.com/conflict onflict@example.com) ];
	ok(!run_script($cmd, $env, $rdr), 'fails on D/F conflict');
}

SKIP: {
	require_mods(qw(DBD::SQLite Search::Xapian), 2);
	require_git(2.6, 1) or skip "git 2.6+ required", 2;
	use_ok 'PublicInbox::Msgmap';
	local $ENV{PI_DIR} = "$tmpdir/.public-inbox/";
	local $ENV{PI_EMERGENCY} = "$tmpdir/.public-inbox/emergency";
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
		ok(!$ibx->{-skip_docdata}, 'docdata written by default');
	}
	for my $v (1, 2) {
		my $name = "v$v-skip-docdata";
		my $dir = "$tmpdir/$name";
		$cmd = [ '-init', $name, "-V$v", '--skip-docdata',
			$dir, "http://example.com/$name",
			"$name\@example.com" ];
		ok(run_script($cmd), "-init -V$v --skip-docdata");
		my $ibx = PublicInbox::Inbox->new({ inboxdir => $dir });
		is(PublicInbox::Admin::detect_indexlevel($ibx), 'full',
			"detected default indexlevel -V$v");
		ok($ibx->{-skip_docdata}, "docdata skip set -V$v");
		ok($ibx->search->has_threadid, 'has_threadid flag set on new inbox');
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
	$cmd = [ qw(-init -V2 -Lbasic --skip-artnum=12 skip3), "$tmpdir/skip3",
		   qw(http://example.com/skip3), $addr ];
	ok(run_script($cmd), '--skip-artnum -V2');
	my $env = { ORIGINAL_RECIPIENT => $addr };
	my $mid = 'skip-artnum@example.com';
	my $msg = "Message-ID: <$mid>\n\n";
	my $rdr = { 0 => \$msg, 2 => \(my $err = '')  };
	ok(run_script([qw(-mda --no-precheck)], $env, $rdr), 'deliver V1');
	diag "err=$err" if $err;
	my $mm = PublicInbox::Msgmap->new_file("$tmpdir/skip3/msgmap.sqlite3");
	my $n = $mm->num_for($mid);
	is($n, 13, 'V2 NNTP article numbers skipped via --skip-artnum');

	$addr = 'skip4@example.com';
	$env = { ORIGINAL_RECIPIENT => $addr };
	$cmd = [ qw(-init -V1 --skip-artnum 12 -Lmedium skip4), "$tmpdir/skip4",
		   qw(http://example.com/skip4), $addr ];
	ok(run_script($cmd), '--skip-artnum -V1');
	$err = '';
	ok(run_script([qw(-mda --no-precheck)], $env, $rdr), 'deliver V1');
	diag "err=$err" if $err;
	$mm = PublicInbox::Msgmap->new_file(
			"$tmpdir/skip4/public-inbox/msgmap.sqlite3");
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
