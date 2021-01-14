#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use POSIX qw(_exit);
require_ok 'PublicInbox::LeiOverview';

my $ovv = bless {}, 'PublicInbox::LeiOverview';
$ovv->ovv_out_lk_init;
my $lock_path = $ovv->{lock_path};
ok(-f $lock_path, 'lock init');
undef $ovv;
ok(!-f $lock_path, 'lock DESTROY');

$ovv = bless {}, 'PublicInbox::LeiOverview';
$ovv->ovv_out_lk_init;
$lock_path = $ovv->{lock_path};
ok(-f $lock_path, 'lock init #2');
my $pid = fork // BAIL_OUT "fork $!";
if ($pid == 0) {
	undef $ovv;
	_exit(0);
}
is(waitpid($pid, 0), $pid, 'child exited');
is($?, 0, 'no error in child process');
ok(-f $lock_path, 'lock was not destroyed by child');
undef $ovv;
ok(!-f $lock_path, 'lock DESTROY #2');

done_testing;
