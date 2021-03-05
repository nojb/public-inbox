#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use POSIX qw(WTERMSIG WIFSIGNALED SIGPIPE);
require_mods(qw(json DBD::SQLite Search::Xapian));
# XXX this needs an already configured lei instance with many messages

my $do_test = sub {
	my $env = shift // {};
	for my $out ([], [qw(-f mboxcl2)]) {
		pipe(my ($r, $w)) or BAIL_OUT $!;
		open my $err, '+>', undef or BAIL_OUT $!;
		my $opt = { run_mode => 0, 1 => $w, 2 => $err };
		my $cmd = [qw(lei q -q -t), @$out, 'z:1..'];
		my $tp = start_script($cmd, $env, $opt);
		close $w;
		sysread($r, my $buf, 1);
		close $r; # trigger SIGPIPE
		$tp->join;
		ok(WIFSIGNALED($?), "signaled @$out");
		is(WTERMSIG($?), SIGPIPE, "got SIGPIPE @$out");
		seek($err, 0, 0);
		my @err = grep(!m{mkdir /dev/null\b}, <$err>);
		is_deeply(\@err, [], "no errors @$out");
	}
};

my ($tmp, $for_destroy) = tmpdir();
my $pid;
my $opt = { run_mode => 0, 1 => \(my $out = '') };
if (run_script([qw(lei daemon-pid)], undef, $opt)) {
	chomp($pid = $out);
	mkdir "$tmp/d" or BAIL_OUT $!;
	local $ENV{TMPDIR} = "$tmp/d";
	$do_test->();
	$out = '';
	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid again');
	chomp($out);
	is($out, $pid, 'daemon-pid unchanged');
	ok(kill(0, $pid), 'daemon still running');
	$out = '';
}
{
	mkdir "$tmp/1" or BAIL_OUT $!;
	local $ENV{TMPDIR} = "$tmp/1";
	$do_test->({XDG_RUNTIME_DIR => '/dev/null'});
	is(unlink(glob("$tmp/1/*")), 0, 'nothing left over w/ oneshot');
}

# the one-shot test should be slow enough that the daemon has cleaned
# up in the background:
is_deeply([glob("$tmp/d/*")], [], 'nothing left over with daemon');

done_testing;
