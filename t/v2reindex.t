# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::ContentId qw(content_digest);
use File::Temp qw/tempdir/;
use File::Path qw(remove_tree);

foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for v2reindex.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
my $mainrepo = tempdir('pi-v2reindex-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx_config = {
	mainrepo => $mainrepo,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
my $ibx = PublicInbox::Inbox->new($ibx_config);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);
local $ENV{NPROC} = 2;
my $im = PublicInbox::V2Writable->new($ibx, 1);
foreach my $i (1..10) {
	$mime->header_set('Message-Id', "<$i\@example.com>");
	ok($im->add($mime), "message $i added");
	if ($i == 4) {
		$im->remove($mime);
	}
}

if ('test remove later') {
	$mime->header_set('Message-Id', "<5\@example.com>");
	$im->remove($mime);
}

$im->done;
my $minmax = [ $ibx->mm->minmax ];
ok(defined $minmax->[0] && defined $minmax->[1], 'minmax defined');
is_deeply($minmax, [ 1, 10 ], 'minmax as expected');

eval { $im->index_sync({reindex => 1}) };
is($@, '', 'no error from reindexing');
$im->done;

my $xap = "$mainrepo/xap".PublicInbox::Search::SCHEMA_VERSION();
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed');
eval { $im->index_sync({reindex => 1}) };
is($@, '', 'no error from reindexing');
$im->done;
ok(-d $xap, 'Xapian directories recreated');

delete $ibx->{mm};
is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');

ok(unlink "$mainrepo/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is(scalar(@warn), 0, 'no warnings from reindexing');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
}

ok(unlink "$mainrepo/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
}

done_testing();
