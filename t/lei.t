#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
my $json = PublicInbox::Config::json() or plan skip_all => 'JSON missing';
require_mods(qw(DBD::SQLite Search::Xapian));
my ($home, $for_destroy) = tmpdir();
my $opt = { 1 => \(my $out = ''), 2 => \(my $err = '') };

SKIP: {
	require_mods('IO::FDPass', 51);
	local $ENV{XDG_RUNTIME_DIR} = "$home/xdg_run";
	mkdir "$home/xdg_run", 0700 or BAIL_OUT "mkdir: $!";
	my $sock = "$ENV{XDG_RUNTIME_DIR}/lei/sock";

	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	is($err, '', 'no error from daemon-pid');
	like($out, qr/\A[0-9]+\n\z/s, 'pid returned') or BAIL_OUT;
	chomp(my $pid = $out);
	ok(kill(0, $pid), 'pid is valid');
	ok(-S $sock, 'sock created');

	ok(!run_script([qw(lei)], undef, $opt), 'no args fails');
	is($? >> 8, 1, '$? is 1');
	is($out, '', 'nothing in stdout');
	like($err, qr/^usage:/sm, 'usage in stderr');

	for my $arg (['-h'], ['--help'], ['help'], [qw(daemon-pid --help)]) {
		$out = $err = '';
		ok(run_script(['lei', @$arg], undef, $opt), "lei @$arg");
		like($out, qr/^usage:/sm, "usage in stdout (@$arg)");
		is($err, '', "nothing in stderr (@$arg)");
	}

	ok(!run_script([qw(lei DBG-false)], undef, $opt), 'false(1) emulation');
	is($? >> 8, 1, '$? set correctly');
	is($err, '', 'no error from false(1) emulation');

	for my $arg ([''], ['--halp'], ['halp'], [qw(daemon-pid --halp)]) {
		$out = $err = '';
		ok(!run_script(['lei', @$arg], undef, $opt), "lei @$arg");
		is($? >> 8, 1, '$? set correctly');
		isnt($err, '', 'something in stderr');
		is($out, '', 'nothing in stdout');
	}

	$out = '';
	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	chomp(my $pid_again = $out);
	is($pid, $pid_again, 'daemon-pid idempotent');

	ok(run_script([qw(lei daemon-stop)], undef, $opt), 'daemon-stop');
	is($out, '', 'no output from daemon-stop');
	is($err, '', 'no error from daemon-stop');
	for (0..100) {
		kill(0, $pid) or last;
		tick();
	}
	ok(!-S $sock, 'sock gone');
	ok(!kill(0, $pid), 'pid gone after stop');

	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	chomp(my $new_pid = $out);
	ok(kill(0, $new_pid), 'new pid is running');
	ok(-S $sock, 'sock exists again');
	unlink $sock or BAIL_OUT "unlink $!";
	for (0..100) {
		kill('CHLD', $new_pid) or last;
		tick();
	}
	ok(!kill(0, $new_pid), 'daemon exits after unlink');
};

require_ok 'PublicInbox::LeiDaemon';

done_testing;
