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
	plan skip_all => "$mod missing for v1reindex.t" if $@;
}
use_ok 'PublicInbox::SearchIdx';
use_ok 'PublicInbox::Import';
my $mainrepo = tempdir('pi-v1reindex-XXXXXX', TMPDIR => 1, CLEANUP => 1);
is(system(qw(git init -q --bare), $mainrepo), 0);
my $ibx_config = {
	mainrepo => $mainrepo,
	name => 'test-v1reindex',
	-primary_address => 'test@example.com',
	indexlevel => 'full',
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
my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
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
my $rw = PublicInbox::SearchIdx->new($ibx, 1);
eval { $rw->index_sync() };
is($@, '', 'no error from indexing');

my $minmax = [ $ibx->mm->minmax ];
ok(defined $minmax->[0] && defined $minmax->[1], 'minmax defined');
is_deeply($minmax, [ 1, 10 ], 'minmax as expected');

$rw = PublicInbox::SearchIdx->new($ibx, 1);
eval { $rw->index_sync({reindex => 1}) };
is($@, '', 'no error from reindexing');
$im->done;

my $xap = "$mainrepo/public-inbox/xapian".PublicInbox::Search::SCHEMA_VERSION();
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed');
$rw = PublicInbox::SearchIdx->new($ibx, 1);

eval { $rw->index_sync({reindex => 1}) };
is($@, '', 'no error from reindexing');
$im->done;
ok(-d $xap, 'Xapian directories recreated');

delete $ibx->{mm};
is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');

ok(unlink "$mainrepo/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');

$rw = PublicInbox::SearchIdx->new($ibx, 1);
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is(scalar(@warn), 0, 'no warnings from reindexing');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
}

ok(unlink "$mainrepo/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');

$rw = PublicInbox::SearchIdx->new($ibx, 1);
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
}

ok(unlink "$mainrepo/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');

$ibx_config->{index_level} = 'medium';
$ibx = PublicInbox::Inbox->new($ibx_config);
$rw = PublicInbox::SearchIdx->new($ibx, 1);
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
}


ok(unlink "$mainrepo/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');

$ibx_config->{index_level} = 'basic';
$ibx = PublicInbox::Inbox->new($ibx_config);
$rw = PublicInbox::SearchIdx->new($ibx, 1);
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
}


done_testing();
