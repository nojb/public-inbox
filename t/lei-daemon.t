#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;

test_lei({ daemon_only => 1 }, sub {
	my $sock = "$ENV{XDG_RUNTIME_DIR}/lei/5.seq.sock";
	my $err_log = "$ENV{XDG_RUNTIME_DIR}/lei/errors.log";
	lei_ok('daemon-pid');
	is($lei_err, '', 'no error from daemon-pid');
	like($lei_out, qr/\A[0-9]+\n\z/s, 'pid returned') or BAIL_OUT;
	chomp(my $pid = $lei_out);
	ok(kill(0, $pid), 'pid is valid');
	ok(-S $sock, 'sock created');
	is(-s $err_log, 0, 'nothing in errors.log');
	open my $efh, '>>', $err_log or BAIL_OUT $!;
	print $efh "phail\n" or BAIL_OUT $!;
	close $efh or BAIL_OUT $!;

	lei_ok('daemon-pid');
	chomp(my $pid_again = $lei_out);
	is($pid, $pid_again, 'daemon-pid idempotent');
	like($lei_err, qr/phail/, 'got mock "phail" error previous run');

	lei_ok(qw(daemon-kill));
	is($lei_out, '', 'no output from daemon-kill');
	is($lei_err, '', 'no error from daemon-kill');
	for (0..100) {
		kill(0, $pid) or last;
		tick();
	}
	ok(-S $sock, 'sock still exists');
	ok(!kill(0, $pid), 'pid gone after stop');

	lei_ok(qw(daemon-pid));
	chomp(my $new_pid = $lei_out);
	ok(kill(0, $new_pid), 'new pid is running');
	ok(-S $sock, 'sock still exists');

	for my $sig (qw(-0 -CHLD)) {
		lei_ok('daemon-kill', $sig, \"handles $sig");
	}
	is($lei_out.$lei_err, '', 'no output on innocuous signals');
	lei_ok('daemon-pid');
	chomp $lei_out;
	is($lei_out, $new_pid, 'PID unchanged after -0/-CHLD');

	if ('socket inaccessible') {
		chmod 0000, $sock or BAIL_OUT "chmod 0000: $!";
		lei_ok('help', \'connect fail, one-shot fallback works');
		like($lei_err, qr/\bconnect\(/, 'connect error noted');
		like($lei_out, qr/^usage: /, 'help output works');
		chmod 0700, $sock or BAIL_OUT "chmod 0700: $!";
	}
	unlink $sock or BAIL_OUT "unlink($sock) $!";
	for (0..100) {
		kill('CHLD', $new_pid) or last;
		tick();
	}
	ok(!kill(0, $new_pid), 'daemon exits after unlink');
});

done_testing;
