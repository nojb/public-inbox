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
$over->dbh; # open file
is($over->max, 0, 'max is zero on new DB (scalar context)');
is_deeply([$over->max], [0], 'max is zero on new DB (list context)');
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
ok($over->dbh->{ReadOnly}, 'Over is ReadOnly');

$over = PublicInbox::OverIdx->new("$tmpdir/over.sqlite3");
$over->dbh;
is($over->sid('hello-world'), $x, 'idempotent across reopen');
$over->each_by_mid('never', sub { fail('should not be called') });

$x = $over->create_ghost('never');
is(int($x), $x, 'integer tid for ghost');
$y = $over->create_ghost('NEVAR');
is($y, $x + 1, 'integer tid for ghost increases');

my $ddd = compress('');
my $msg = sub { { ts => 0, ds => 0, num => $_[0] } };
foreach my $s ('', undef) {
	$over->add_over($msg->(98), [ 'a' ], [], $s, $ddd);
	$over->add_over($msg->(99), [ 'b' ], [], $s, $ddd);
	my $msgs = [ map { $_->{num} } @{$over->get_thread('a')} ];
	is_deeply([98], $msgs,
		'messages not linked by empty subject');
}

$over->add_over($msg->(98), [ 'a' ], [], 's', $ddd);
$over->add_over($msg->(99), [ 'b' ], [], 's', $ddd);
foreach my $mid (qw(a b)) {
	my $msgs = [ map { $_->{num} } @{$over->get_thread('a')} ];
	is_deeply([98, 99], $msgs, 'linked messages by subject');
}
$over->add_over($msg->(98), [ 'a' ], [], 's', $ddd);
$over->add_over($msg->(99), [ 'b' ], ['a'], 'diff', $ddd);
foreach my $mid (qw(a b)) {
	my $msgs = [ map { $_->{num} } @{$over->get_thread($mid)} ];
	is_deeply([98, 99], $msgs, "linked messages by Message-ID: <$mid>");
}
isnt($over->max, 0, 'max is non-zero');

$over->rollback_lazy;

# L<perldata/"Version Strings">
my $v = eval 'v'.$over->{dbh}->{sqlite_version};
SKIP: {
	skip("no WAL in SQLite version $v < 3.7.0", 1) if $v lt v3.7.0;
	$over->{dbh}->do('PRAGMA journal_mode = WAL');
	$over = PublicInbox::OverIdx->new("$tmpdir/over.sqlite3");
	is($over->dbh->selectrow_array('PRAGMA journal_mode'), 'wal',
		'WAL journal_mode not clobbered if manually set');
}

done_testing();
