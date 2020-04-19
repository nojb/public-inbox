# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::ContentId qw(content_digest);
use File::Path qw(remove_tree);
use PublicInbox::TestCommon;
require_git(2.6);
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::SearchIdx';
use_ok 'PublicInbox::Import';
my ($inboxdir, $for_destroy) = tmpdir();
my $ibx_config = {
	inboxdir => $inboxdir,
	name => 'test-v1reindex',
	-primary_address => 'test@example.com',
	indexlevel => 'full',
};
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);
my $minmax;
my $msgmap;
my ($mark1, $mark2, $mark3, $mark4);
{
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	$im->init_bare;
	foreach my $i (1..10) {
		$mime->header_set('Message-Id', "<$i\@example.com>");
		ok($im->add($mime), "message $i added");
		if ($i == 4) {
			$mark1 = $im->get_mark($im->{tip});
			$im->remove($mime);
			$mark2 = $im->get_mark($im->{tip});
		}
	}

	if ('test remove later') {
		$mark3 = $im->get_mark($im->{tip});
		$mime->header_set('Message-Id', "<5\@example.com>");
		$im->remove($mime);
		$mark4 = $im->get_mark($im->{tip});
	}

	$im->done;
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync() };
	is($@, '', 'no error from indexing');

	$minmax = [ $ibx->mm->minmax ];
	ok(defined $minmax->[0] && defined $minmax->[1], 'minmax defined');
	is_deeply($minmax, [ 1, 10 ], 'minmax as expected');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = @$minmax;
	$msgmap = $ibx->mm->msg_range(\$min, $max);
	is_deeply($msgmap, [
			  [1, '1@example.com' ],
			  [2, '2@example.com' ],
			  [3, '3@example.com' ],
			  [6, '6@example.com' ],
			  [7, '7@example.com' ],
			  [8, '8@example.com' ],
			  [9, '9@example.com' ],
			  [10, '10@example.com' ],
		  ], 'msgmap as expected');
}

{
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing');
	$im->done;

	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

my $xap = "$inboxdir/public-inbox/xapian".PublicInbox::Search::SCHEMA_VERSION();
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed');
{
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);

	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');

	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is(scalar(@warn), 0, 'no warnings from reindexing');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = @$minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	$config{indexlevel} = 'medium';
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	my $mset = $ibx->search->query('hello world', {mset=>1});
	isnt($mset->size, 0, 'got Xapian search results');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	$config{indexlevel} = 'basic';
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	isnt($ibx->search, 'no search for basic');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

# upgrade existing basic to medium
# note: changing indexlevels is not yet supported in v2,
# and may not be without more effort
# no removals
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	$config{indexlevel} = 'medium';
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	eval { $rw->index_sync };
	is($@, '', 'no error from indexing');
	is_deeply(\@warn, [], 'no warnings');
	my $mset = $ibx->search->reopen->query('hello world', {mset=>1});
	isnt($mset->size, 0, 'search OK after basic -> medium');

	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

# An incremental indexing test
ok(unlink "$inboxdir/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark1 4 simple additions in the same index_sync
	eval { $rw->index_sync({ref => $mark1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 4, 'max as expected');
	is($ibx->mm->num_highwater, 4, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		   [4, '4@example.com' ],
		  ], 'msgmap as expected' );
}
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark2 A delete separated form and add in the same index_sync
	eval { $rw->index_sync({ref => $mark2}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 3, 'max as expected');
	is($ibx->mm->num_highwater, 4, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		  ], 'msgmap as expected' );
}
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark3 adds following the delete at mark2
	eval { $rw->index_sync({ref => $mark3}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 10, 'max as expected');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		   [5, '5@example.com' ],
		   [6, '6@example.com' ],
		   [7, '7@example.com' ],
		   [8, '8@example.com' ],
		   [9, '9@example.com' ],
		   [10, '10@example.com' ],
		  ], 'msgmap as expected' );
}
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark4 A delete of an older message
	eval { $rw->index_sync({ref => $mark4}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 10, 'max as expected');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		   [6, '6@example.com' ],
		   [7, '7@example.com' ],
		   [8, '8@example.com' ],
		   [9, '9@example.com' ],
		   [10, '10@example.com' ],
		  ], 'msgmap as expected' );
}


# Another incremental indexing test
ok(unlink "$inboxdir/public-inbox/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark2 an add and it's delete in the same index_sync
	eval { $rw->index_sync({ref => $mark2}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 3, 'max as expected');
	is($ibx->mm->num_highwater, 4, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		  ], 'msgmap as expected' );
}
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark3 adds following the delete at mark2
	eval { $rw->index_sync({ref => $mark3}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 10, 'max as expected');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		   [5, '5@example.com' ],
		   [6, '6@example.com' ],
		   [7, '7@example.com' ],
		   [8, '8@example.com' ],
		   [9, '9@example.com' ],
		   [10, '10@example.com' ],
		  ], 'msgmap as expected' );
}
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	# mark4 A delete of an older message
	eval { $rw->index_sync({ref => $mark4}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	my ($min, $max) = $ibx->mm->minmax;
	is($min, 1, 'min as expected');
	is($max, 10, 'max as expected');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	is_deeply($ibx->mm->msg_range(\$min, $max),
		  [
		   [1, '1@example.com' ],
		   [2, '2@example.com' ],
		   [3, '3@example.com' ],
		   [6, '6@example.com' ],
		   [7, '7@example.com' ],
		   [8, '8@example.com' ],
		   [9, '9@example.com' ],
		   [10, '10@example.com' ],
		  ], 'msgmap as expected' );
}


done_testing();
