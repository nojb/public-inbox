#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite));
use_ok 'PublicInbox::SharedKV';
my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{TMPDIR} = $tmpdir;
my $skv = PublicInbox::SharedKV->new;
my $skv_tmpdir = $skv->{"tmp$$.$skv"};
ok(-d $skv_tmpdir, 'created a temporary dir');
$skv->dbh;
my $dead = "\xde\xad";
my $beef = "\xbe\xef";
my $cafe = "\xca\xfe";
ok($skv->set($dead, $beef), 'set');
is($skv->get($dead), $beef, 'get');
ok($skv->set($dead, $beef), 'set idempotent');
ok(!$skv->set_maybe($dead, $cafe), 'set_maybe ignores');
ok($skv->set_maybe($cafe, $dead), 'set_maybe sets');
is($skv->xchg($dead, $cafe), $beef, 'xchg');
is($skv->get($dead), $cafe, 'get after xchg');
is($skv->xchg($dead, undef), $cafe, 'xchg to undef');
is($skv->get($dead), undef, 'get after xchg to undef');
is($skv->get($cafe), $dead, 'get after set_maybe');
is($skv->xchg($dead, $cafe), undef, 'xchg from undef');
is($skv->count, 2, 'count works');

my %seen;
my $sth = $skv->each_kv_iter;
while (my ($k, $v) = $sth->fetchrow_array) {
	$seen{$k} = $v;
}
is($seen{$dead}, $cafe, '$dead has expected value');
is($seen{$cafe}, $dead, '$cafe has expected value');
is(scalar keys %seen, 2, 'iterated through all');

undef $skv;
ok(!-d $skv_tmpdir, 'temporary dir gone');
$skv = PublicInbox::SharedKV->new("$tmpdir/dir", 'base');
ok(-e "$tmpdir/dir/base.sqlite3", 'file created');

done_testing;
