#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use File::Path qw(rmtree);
require_mods(qw(json DBD::SQLite Search::Xapian));
my $LEI = 'lei';
my $lei = sub {
	my ($cmd, $env, $opt) = @_;
	run_script([$LEI, @$cmd], $env, $opt);
};

my ($home, $for_destroy) = tmpdir();
my $opt = { 1 => \(my $out = ''), 2 => \(my $err = '') };
delete local $ENV{XDG_DATA_HOME};
delete local $ENV{XDG_CONFIG_HOME};
local $ENV{XDG_RUNTIME_DIR} = "$home/xdg_run";
local $ENV{HOME} = $home;
mkdir "$home/xdg_run", 0700 or BAIL_OUT "mkdir: $!";

my $test_lei_common = sub {
	ok(!$lei->([], undef, $opt), 'no args fails');
	is($? >> 8, 1, '$? is 1');
	is($out, '', 'nothing in stdout');
	like($err, qr/^usage:/sm, 'usage in stderr');

	for my $arg (['-h'], ['--help'], ['help'], [qw(daemon-pid --help)]) {
		$out = $err = '';
		ok($lei->($arg, undef, $opt), "lei @$arg");
		like($out, qr/^usage:/sm, "usage in stdout (@$arg)");
		is($err, '', "nothing in stderr (@$arg)");
	}

	for my $arg ([''], ['--halp'], ['halp'], [qw(daemon-pid --halp)]) {
		$out = $err = '';
		ok(!$lei->($arg, undef, $opt), "lei @$arg");
		is($? >> 8, 1, '$? set correctly');
		isnt($err, '', 'something in stderr');
		is($out, '', 'nothing in stdout');
	}

	# init tests
	$out = $err = '';
	my $ok_err_info = sub {
		my ($msg) = @_;
		is(grep(!/^I:/, split(/^/, $err)), 0, $msg) or
			diag "$msg: err=$err";
		$err = '';
	};
	my $home_trash = [ "$home/.local", "$home/.config" ];
	rmtree($home_trash);
	ok($lei->(['init'], undef, $opt), 'init w/o args');
	$ok_err_info->('after init w/o args');
	ok($lei->(['init'], undef, $opt), 'idempotent init w/o args');
	$ok_err_info->('after idempotent init w/o args');

	ok(!$lei->(['init', "$home/x"], undef, $opt),
		'init conflict');
	is(grep(/^E:/, split(/^/, $err)), 1, 'got error on conflict');
	ok(!-e "$home/x", 'nothing created on conflict');
	rmtree($home_trash);

	$err = '';
	ok($lei->(['init', "$home/x"], undef, $opt), 'init conflict resolved');
	$ok_err_info->('init w/ arg');
	ok($lei->(['init', "$home/x"], undef, $opt), 'init idempotent w/ path');
	$ok_err_info->('init idempotent w/ arg');
	ok(-d "$home/x", 'created dir');
	rmtree([ "$home/x", @$home_trash ]);

	$err = '';
	ok(!$lei->(['init', "$home/x", "$home/2" ], undef, $opt),
		'too many args fails');
	like($err, qr/too many/, 'noted excessive');
	ok(!-e "$home/x", 'x not created on excessive');
	for my $d (@$home_trash) {
		my $base = (split(m!/!, $d))[-1];
		ok(!-d $d, "$base not created");
	}
	is($out, '', 'nothing in stdout');
};

my $test_lei_oneshot = $ENV{TEST_LEI_ONESHOT};
SKIP: {
	last SKIP if $test_lei_oneshot;
	require_mods('IO::FDPass', 16);
	my $sock = "$ENV{XDG_RUNTIME_DIR}/lei/sock";

	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	is($err, '', 'no error from daemon-pid');
	like($out, qr/\A[0-9]+\n\z/s, 'pid returned') or BAIL_OUT;
	chomp(my $pid = $out);
	ok(kill(0, $pid), 'pid is valid');
	ok(-S $sock, 'sock created');

	$test_lei_common->();

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
	# success over socket, can't test without
	$test_lei_common = undef;
};

require_ok 'PublicInbox::LeiDaemon';
$LEI = 'lei-oneshot' if $test_lei_oneshot;
$test_lei_common->() if $test_lei_common;

done_testing;
