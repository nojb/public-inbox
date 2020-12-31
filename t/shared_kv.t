#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::SharedKV';
my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{TMPDIR} = $tmpdir;
my $skv = PublicInbox::SharedKV->new;
opendir(my $dh, $tmpdir) or BAIL_OUT $!;
my @ent = grep(!/\A\.\.?\z/, readdir($dh));
is(scalar(@ent), 1, 'created a temporary dir');
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
ok($skv->index_values, 'index_values works');
is($skv->replace_values($dead, $cafe), 1, 'replaced one by value');
is($skv->get($cafe), $cafe, 'value updated');
is($skv->replace_values($dead, $cafe), 0, 'replaced none by value');
is($skv->xchg($dead, $cafe), undef, 'xchg from undef');
is($skv->count, 2, 'count works');

my %seen;
my $sth = $skv->each_kv_iter;
while (my ($k, $v) = $sth->fetchrow_array) {
	$seen{$k} = $v;
}
is($seen{$dead}, $cafe, '$dead has expected value');
is($seen{$cafe}, $cafe, '$cafe has expected value');
is(scalar keys %seen, 2, 'iterated through all');

is($skv->replace_values($cafe, $dead), 2, 'replaced 2 by value');
is($skv->delete_by_val('bogus'), 0, 'delete_by_val misses');
is($skv->delete_by_val($dead), 2, 'delete_by_val hits');
is($skv->delete_by_val($dead), 0, 'delete_by_val misses again');

undef $skv;
rewinddir($dh);
@ent = grep(!/\A\.\.?\z/, readdir($dh));
is(scalar(@ent), 0, 'temporary dir gone');
undef $dh;
$skv = PublicInbox::SharedKV->new("$tmpdir/dir", 'base');
ok(-e "$tmpdir/dir/base.sqlite3", 'file created');

done_testing;
