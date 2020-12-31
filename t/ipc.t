#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
require_ok 'PublicInbox::IPC';
state $once = eval <<'';
package PublicInbox::IPC;
use strict;
sub test_array { qw(test array) }
sub test_scalar { 'scalar' }
sub test_scalarref { \'scalarref' }
sub test_undef { undef }
sub test_die { shift; die @_; 'unreachable' }
sub test_pid { $$ }
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
};
$test->('local');

SKIP: {
	require_mods(qw(Storable||Sereal), 16);
	my $pid = $ipc->ipc_worker_spawn('test worker');
	ok($pid > 0 && kill(0, $pid), 'worker spawned and running');
	defined($pid) or BAIL_OUT 'no spawn, no test';
	is($ipc->ipc_do('test_pid'), $pid, 'worker pid returned');
	$test->('worker');
	{
		my ($tmp, $for_destroy) = tmpdir();
		$ipc->ipc_lock_init("$tmp/lock");
		is($ipc->ipc_do('test_pid'), $pid, 'worker pid returned');
	}
	$ipc->ipc_worker_stop;
	ok(!kill(0, $pid) && $!{ESRCH}, 'worker stopped');
}
$ipc->ipc_worker_stop; # idempotent
done_testing;
