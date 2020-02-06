# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Compress::Zlib qw(compress);
use PublicInbox::TestCommon;
require_mods('DBD::SQLite');
use_ok 'PublicInbox::OverIdx';
my ($tmpdir, $for_destroy) = tmpdir();
my $over = PublicInbox::OverIdx->new("$tmpdir/over.sqlite3");
$over->connect;
my $x = $over->next_tid;
is(int($x), $x, 'integer tid');
my $y = $over->next_tid;
is($y, $x+1, 'tid increases');

$x = $over->sid('hello-world');
is(int($x), $x, 'integer sid');
$y = $over->sid('hello-WORLD');
is($y, $x+1, 'sid increases');
is($over->sid('hello-world'), $x, 'idempotent');
ok(!$over->{dbh}->{ReadOnly}, 'OverIdx is not ReadOnly');
$over->disconnect;

$over = PublicInbox::Over->new("$tmpdir/over.sqlite3");
$over->connect;
ok($over->{dbh}->{ReadOnly}, 'Over is ReadOnly');

$over = PublicInbox::OverIdx->new("$tmpdir/over.sqlite3");
$over->connect;
is($over->sid('hello-world'), $x, 'idempotent across reopen');
$over->each_by_mid('never', sub { fail('should not be called') });

$x = $over->create_ghost('never');
is(int($x), $x, 'integer tid for ghost');
$y = $over->create_ghost('NEVAR');
is($y, $x + 1, 'integer tid for ghost increases');

my $ddd = compress('');
foreach my $s ('', undef) {
	$over->add_over([0, 0, 98, [ 'a' ], [], $s, $ddd]);
	$over->add_over([0, 0, 99, [ 'b' ], [], $s, $ddd]);
	my $msgs = [ map { $_->{num} } @{$over->get_thread('a')} ];
	is_deeply([98], $msgs,
		'messages not linked by empty subject');
}

$over->add_over([0, 0, 98, [ 'a' ], [], 's', $ddd]);
$over->add_over([0, 0, 99, [ 'b' ], [], 's', $ddd]);
foreach my $mid (qw(a b)) {
	my $msgs = [ map { $_->{num} } @{$over->get_thread('a')} ];
	is_deeply([98, 99], $msgs, 'linked messages by subject');
}
$over->add_over([0, 0, 98, [ 'a' ], [], 's', $ddd]);
$over->add_over([0, 0, 99, [ 'b' ], ['a'], 'diff', $ddd]);
foreach my $mid (qw(a b)) {
	my $msgs = [ map { $_->{num} } @{$over->get_thread($mid)} ];
	is_deeply([98, 99], $msgs, "linked messages by Message-ID: <$mid>");
}

$over->rollback_lazy;

done_testing();
