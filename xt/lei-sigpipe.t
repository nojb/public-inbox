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
	pipe(my ($r, $w)) or BAIL_OUT $!;
	open my $err, '+>', undef or BAIL_OUT $!;
	my $opt = { run_mode => 0, 1 => $w, 2 => $err };
	my $tp = start_script([qw(lei q -t), 'bytes:1..'], $env, $opt);
	close $w;
	sysread($r, my $buf, 1);
	close $r; # trigger SIGPIPE
	$tp->join;
	ok(WIFSIGNALED($?), 'signaled');
	is(WTERMSIG($?), SIGPIPE, 'got SIGPIPE');
	seek($err, 0, 0);
	my @err = grep(!m{mkdir /dev/null\b}, <$err>);
	is_deeply(\@err, [], 'no errors');
};

$do_test->();
$do_test->({XDG_RUNTIME_DIR => '/dev/null'});

done_testing;
