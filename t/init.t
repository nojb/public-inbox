# Copyright (C) 2014-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use File::Temp qw/tempdir/;
require './t/common.perl';
my $tmpdir = tempdir('pi-init-XXXXXX', TMPDIR => 1, CLEANUP => 1);
use File::Basename;
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

SKIP: {
	foreach my $mod (qw(DBD::SQLite Search::Xapian::WritableDatabase)) {
		eval "require $mod";
		skip "$mod missing for v2", 2 if $@;
	}
	require_git(2.6, 1) or skip "git 2.6+ required", 2;
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
		$cmd = [ '-init', "v2$lvl", '-V2', '-L', $lvl,
			"$tmpdir/v2$lvl", "http://example.com/v2$lvl",
			"v2$lvl\@example.com" ];
		ok(run_script($cmd), "-init -L $lvl");
		is(read_indexlevel("v2$lvl"), $lvl, "indexlevel set to '$lvl'");
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
}

done_testing();

sub read_indexlevel {
	my ($inbox) = @_;
	local $ENV{GIT_CONFIG} = "$ENV{PI_DIR}/config";
	chomp(my $lvl = `git config publicinbox.$inbox.indexlevel`);
	$lvl;
}
