# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;

foreach my $mod (qw(DBD::SQLite)) {
	eval "require $mod";
	plan skip_all => "$mod missing for nntpd.t" if $@;
}

use_ok 'PublicInbox::Msgmap';
my $tmpdir = tempdir('pi-msgmap-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $d = PublicInbox::Msgmap->new($tmpdir, 1);

my %mid2num;
my %num2mid;
my @mids = qw(a@b c@d e@f g@h aa@bb aa@cc);
is_deeply([$d->minmax], [undef,undef], "empty min max on new DB");

foreach my $mid (@mids) {
	my $n = $d->mid_insert($mid);
	ok($n, "mid $mid inserted");
	$mid2num{$mid} = $n;
	$num2mid{$n} = $mid;
}

$@ = undef;
my $ret = $d->mid_insert('a@b');
is($ret, undef, 'duplicate mid_insert in undef result');
is($d->num_for('a@b'), $mid2num{'a@b'}, 'existing number not clobbered');

foreach my $n (keys %num2mid) {
	is($d->mid_for($n), $num2mid{$n}, "num:$n maps correctly");
}
foreach my $mid (@mids) {
	is($d->num_for($mid), $mid2num{$mid}, "mid:$mid maps correctly");
}

is_deeply($d->mid_prefixes('a'), [qw(aa@cc aa@bb a@b)], "mid_prefixes match");
is_deeply($d->mid_prefixes('A'), [], "mid_prefixes is case sensitive");

is(undef, $d->last_commit, "last commit not set");
my $lc = 'deadbeef' x 5;
is(undef, $d->last_commit($lc), 'previous last commit (undef) returned');
is($lc, $d->last_commit, 'last commit was set correctly');

my $nc = 'deaddead' x 5;
is($lc, $d->last_commit($nc), 'returned previously set commit');
is($nc, $d->last_commit, 'new commit was set correctly');

is($d->mid_delete('a@b'), 1, 'deleted a@b');
is($d->mid_delete('a@b') + 0, 0, 'delete again returns zero');
is(undef, $d->num_for('a@b'), 'num_for fails on deleted msg');
$d = undef;

ok($d = PublicInbox::Msgmap->new($tmpdir, 1), 'idempotent DB creation');
my ($min, $max) = $d->minmax;
ok($min > 0, "article min OK");
ok($max > 0 && $max < 10, "article max OK");
ok($min < $max, "article counts OK");

my $orig = $d->mid_insert('spam@1');
$d->mid_delete('spam@1');
is($d->mid_insert('spam@2'), 1 + $orig, "last number not recycled");

done_testing();
