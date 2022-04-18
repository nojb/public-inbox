#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Socket qw(AF_UNIX SOCK_SEQPACKET MSG_EOR pack_sockaddr_un);

test_lei({ daemon_only => 1 }, sub {
	my $send_cmd = PublicInbox::Spawn->can('send_cmd4') // do {
		require PublicInbox::CmdIPC4;
		PublicInbox::CmdIPC4->can('send_cmd4');
	} // do {
		require PublicInbox::Syscall;
		PublicInbox::Syscall->can('send_cmd4');
	};
	$send_cmd or BAIL_OUT 'started testing lei-daemon w/o send_cmd4!';

	my $sock = "$ENV{XDG_RUNTIME_DIR}/lei/5.seq.sock";
	my $err_log = "$ENV{XDG_RUNTIME_DIR}/lei/errors.log";
	lei_ok('daemon-pid');
	ignore_inline_c_missing($lei_err);
	is($lei_err, '', 'no error from daemon-pid');
	like($lei_out, qr/\A[0-9]+\n\z/s, 'pid returned') or BAIL_OUT;
	chomp(my $pid = $lei_out);
	ok(kill(0, $pid), 'pid is valid');
	ok(-S $sock, 'sock created');
	is(-s $err_log, 0, 'nothing in errors.log');
	lei_ok('daemon-pid');
	chomp(my $pid_again = $lei_out);
	is($pid, $pid_again, 'daemon-pid idempotent');

	SKIP: {
		skip 'only testing open files on Linux', 1 if $^O ne 'linux';
		my $d = "/proc/$pid/fd";
		skip "no $d on Linux" unless -d $d;
		my @before = sort(glob("$d/*"));
		my $addr = pack_sockaddr_un($sock);
		open my $null, '<', '/dev/null' or BAIL_OUT "/dev/null: $!";
		my @fds = map { fileno($null) } (0..2);
		for (0..10) {
			socket(my $c, AF_UNIX, SOCK_SEQPACKET, 0) or
							BAIL_OUT "socket: $!";
			connect($c, $addr) or BAIL_OUT "connect: $!";
			$send_cmd->($c, \@fds, 'hi',  MSG_EOR);
		}
		lei_ok('daemon-pid');
		chomp($pid = $lei_out);
		is($pid, $pid_again, 'pid unchanged after failed reqs');
		my @after = sort(glob("$d/*"));
		is_deeply(\@before, \@after, 'open files unchanged') or
			diag explain([\@before, \@after]);;
	}
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
	unlink $sock or BAIL_OUT "unlink($sock) $!";
	for (0..100) {
		kill('CHLD', $new_pid) or last;
		tick();
	}
	ok(!kill(0, $new_pid), 'daemon exits after unlink');
});

done_testing;
