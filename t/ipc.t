#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use Fcntl qw(SEEK_SET);
use Digest::SHA qw(sha1_hex);
require_mods(qw(Storable||Sereal));
require_ok 'PublicInbox::IPC';
my ($tmpdir, $for_destroy) = tmpdir();
state $once = eval <<'';
package PublicInbox::IPC;
use strict;
use Digest::SHA qw(sha1_hex);
sub test_array { qw(test array) }
sub test_scalar { 'scalar' }
sub test_scalarref { \'scalarref' }
sub test_undef { undef }
sub test_die { shift; die @_; 'unreachable' }
sub test_pid { $$ }
sub test_write_each_fd {
	my ($self, @args) = @_;
	for my $fd (0..2) {
		print { $self->{$fd} } "i=$fd $$ ", @args, "\n";
		$self->{$fd}->flush;
	}
}
sub test_sha {
	my ($self, $buf) = @_;
	print { $self->{1} } sha1_hex($buf), "\n";
	$self->{1}->flush;
}
sub test_append_pid {
	my ($self, $file) = @_;
	open my $fh, '>>', $file or die "open: $!";
	$fh->autoflush(1);
	print $fh "$$\n" or die "print: $!";
}
1;

my $ipc = bless {}, 'PublicInbox::IPC';
my @t = qw(array scalar scalarref undef);
my $test = sub {
	my $x = shift;
	for my $type (@t) {
		my $m = "test_$type";
		my @ret = $ipc->ipc_do($m);
		my @exp = $ipc->$m;
		is_deeply(\@ret, \@exp, "wantarray $m $x");

		$ipc->ipc_do($m);

		my $ret = $ipc->ipc_do($m);
		my $exp = $ipc->$m;
		is_deeply($ret, $exp, "!wantarray $m $x");
	}
	my $ret = eval { $ipc->test_die('phail') };
	my $exp = $@;
	$ret = eval { $ipc->ipc_do('test_die', 'phail') };
	my $err = $@;
	my %lines;
	for ($err, $exp) {
		s/ line (\d+).*//s and $lines{$1}++;
	}
	is(scalar keys %lines, 1, 'line numbers match');
	is((values %lines)[0], 2, '2 hits on same line number');
	is($err, $exp, "$x die matches");
	is($ret, undef, "$x die did not return");

	eval { $ipc->test_die(['arrayref']) };
	$exp = $@;
	$ret = eval { $ipc->ipc_do('test_die', ['arrayref']) };
	$err = $@;
	is_deeply($err, $exp, 'die with unblessed ref');
	is(ref($err), 'ARRAY', 'got an array ref');

	$exp = bless ['blessed'], 'PublicInbox::WTF';
	$ret = eval { $ipc->ipc_do('test_die', $exp) };
	$err = $@;
	is_deeply($err, $exp, 'die with blessed ref');
	is(ref($err), 'PublicInbox::WTF', 'got blessed ref');
};
$test->('local');

{
	my $pid = $ipc->ipc_worker_spawn('test worker');
	ok($pid > 0 && kill(0, $pid), 'worker spawned and running');
	defined($pid) or BAIL_OUT 'no spawn, no test';
	is($ipc->ipc_do('test_pid'), $pid, 'worker pid returned');
	$test->('worker');
	$ipc->ipc_lock_init("$tmpdir/lock");
	is($ipc->ipc_do('test_pid'), $pid, 'worker pid returned');
	$ipc->ipc_worker_stop;
	ok(!kill(0, $pid) && $!{ESRCH}, 'worker stopped');
}
$ipc->ipc_worker_stop; # idempotent

# work queues
pipe(my ($ra, $wa)) or BAIL_OUT $!;
pipe(my ($rb, $wb)) or BAIL_OUT $!;
pipe(my ($rc, $wc)) or BAIL_OUT $!;
open my $warn, '+>', undef or BAIL_OUT;
$warn->autoflush(0);
local $SIG{__WARN__} = sub { print $warn "PID:$$ ", @_ };
my @ppids;
open my $agpl, '<', 'COPYING' or BAIL_OUT "AGPL-3 missing: $!";
my $big = do { local $/; <$agpl> } // BAIL_OUT "read: $!";
close $agpl or BAIL_OUT "close: $!";

for my $t ('local', 'worker', 'worker again') {
	$ipc->wq_io_do('test_write_each_fd', [ $wa, $wb, $wc ], 'hello world');
	my $i = 0;
	for my $fh ($ra, $rb, $rc) {
		my $buf = readline($fh);
		is(chop($buf), "\n", "trailing CR ($t)");
		like($buf, qr/\Ai=$i \d+ hello world\z/, "got expected ($t)");
		$i++;
	}
	$ipc->wq_io_do('test_die', [ $wa, $wb, $wc ]);
	$ipc->wq_io_do('test_sha', [ $wa, $wb ], 'hello world');
	is(readline($rb), sha1_hex('hello world')."\n", "SHA small ($t)");
	{
		my $bigger = $big x 10; # to hit EMSGSIZE
		$ipc->wq_io_do('test_sha', [ $wa, $wb ], $bigger);
		my $exp = sha1_hex($bigger)."\n";
		is(readline($rb), $exp, "SHA big for EMSGSIZE ($t)");

		# to hit the WQWorker recv_and_run length
		substr($bigger, my $MY_MAX_ARG_STRLEN = 4096 * 33, -1) = '';
		$ipc->wq_io_do('test_sha', [ $wa, $wb ], $bigger);
		$exp = sha1_hex($bigger)."\n";
		is(readline($rb), $exp, "SHA WQWorker limit ($t)");
	}
	my $ppid = $ipc->wq_workers_start('wq', 1);
	push(@ppids, $ppid);
}

# wq_io_do works across fork (siblings can feed)
SKIP: {
	skip 'Socket::MsgHdr or Inline::C missing', 3 if !$ppids[0];
	is_deeply(\@ppids, [$$, undef, undef],
		'parent pid returned in wq_workers_start');
	my $pid = fork // BAIL_OUT $!;
	if ($pid == 0) {
		use POSIX qw(_exit);
		$ipc->wq_io_do('test_write_each_fd', [ $wa, $wb, $wc ], $$);
		_exit(0);
	} else {
		my $i = 0;
		my ($wpid, @rest) = keys %{$ipc->{-wq_workers}};
		is(scalar(@rest), 0, 'only one worker');
		for my $fh ($ra, $rb, $rc) {
			my $buf = readline($fh);
			is(chop($buf), "\n", "trailing CR #$i");
			like($buf, qr/^i=$i $wpid $pid\z/,
				'got expected from sibling');
			$i++;
		}
		is(waitpid($pid, 0), $pid, 'waitpid complete');
		is($?, 0, 'child wq producer exited');
	}
	my @ary = $ipc->wq_do('test_array');
	is_deeply(\@ary, [ qw(test array) ], 'wq_do wantarray');
	is(my $s = $ipc->wq_do('test_scalar'), 'scalar', 'defined wantarray');
	my $exp = bless ['blessed'], 'PublicInbox::WTF';
	my $ret = eval { $ipc->wq_do('test_die', $exp) };
	is_deeply($@, $exp, 'die with blessed ref');
}

$ipc->wq_close;
SKIP: {
	skip 'Socket::MsgHdr or Inline::C missing', 11 if !$ppids[0];
	seek($warn, 0, SEEK_SET) or BAIL_OUT;
	my @warn = <$warn>;
	is(scalar(@warn), 3, 'warned 3 times');
	like($warn[0], qr/ wq_io_do: /, '1st warned from wq_do');
	like($warn[1], qr/ wq_worker: /, '2nd warned from wq_worker');
	is($warn[2], $warn[1], 'worker did not die');

	$SIG{__WARN__} = 'DEFAULT';
	is($ipc->wq_workers_start('wq', 1), $$, 'workers started again');
	is($ipc->wq_workers, 1, '1 worker started');

	$ipc->wq_worker_incr;
	is($ipc->wq_workers, 2, 'worker count bumped');
	$ipc->wq_worker_decr;
	$ipc->wq_worker_decr_wait(10);
	is($ipc->wq_workers, 1, 'worker count lowered');
	is($ipc->wq_workers(2), 2, 'worker count set');
	is($ipc->wq_workers, 2, 'worker count stayed set');

	$ipc->wq_broadcast('test_append_pid', "$tmpdir/append_pid");
	$ipc->wq_close;
	open my $fh, '<', "$tmpdir/append_pid" or BAIL_OUT "open: $!";
	chomp(my @pids = <$fh>);
	my %pids = map { $_ => 1 } grep(/\A[0-9]+\z/, @pids);
	is(scalar keys %pids, 2, 'broadcast hit both PIDs');
	is($ipc->wq_workers, undef, 'workers undef after close');
}

done_testing;
