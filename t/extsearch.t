#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use Fcntl qw(:seek);
require_git(2.6);
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::ExtSearch';
use_ok 'PublicInbox::ExtSearchIdx';
my ($home, $for_destroy) = tmpdir();
local $ENV{HOME} = $home;
mkdir "$home/.public-inbox" or BAIL_OUT $!;
open my $fh, '>', "$home/.public-inbox/config" or BAIL_OUT $!;
print $fh <<EOF or BAIL_OUT $!;
[publicinboxMda]
	spamcheck = none
EOF
close $fh or BAIL_OUT $!;
my $v2addr = 'v2test@example.com';
my $v1addr = 'v1test@example.com';
ok(run_script([qw(-init -V2 v2test), "$home/v2test",
	'http://example.com/v2test', $v2addr ]), 'v2test init');
my $env = { ORIGINAL_RECIPIENT => $v2addr };
open($fh, '<', 't/utf8.eml') or BAIL_OUT("open t/utf8.eml: $!");
run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or BAIL_OUT '-mda';

ok(run_script([qw(-init -V1 v1test), "$home/v1test",
	'http://example.com/v1test', $v1addr ]), 'v1test init');
$env = { ORIGINAL_RECIPIENT => $v1addr };
seek($fh, 0, SEEK_SET) or BAIL_OUT $!;
run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or BAIL_OUT '-mda';
run_script(['-index', "$home/v1test"]) or BAIL_OUT "index $?";

ok(run_script([qw(-eindex --all), "$home/eindex"]), 'eindex init');

done_testing;
