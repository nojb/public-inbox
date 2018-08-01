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
local $ENV{NPROC} = 2;
my $minmax;
my $msgmap;
{
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
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
	$minmax = [ $ibx->mm->minmax ];
	ok(defined $minmax->[0] && defined $minmax->[1], 'minmax defined');
	is_deeply($minmax, [ 1, 10 ], 'minmax as expected');

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
	my $im = PublicInbox::V2Writable->new($ibx, 1);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing');
	$im->done;

	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

my $xap = "$mainrepo/xap".PublicInbox::Search::SCHEMA_VERSION();
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed');
{
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx, 1);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');

	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$mainrepo/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx, 1);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is(scalar(@warn), 0, 'no warnings from reindexing');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

my %sizes;
ok(unlink "$mainrepo/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx, 1);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	my $mset = $ibx->search->query('"hello world"', {mset=>1});
	isnt($mset->size, 0, "phrase search succeeds on indexlevel=full");
	for (<"$xap/*/*">) { $sizes{$ibx->{indexlevel}} += -s _ if -f $_ }

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$mainrepo/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	$config{indexlevel} = 'medium';
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');

	if (0) {
		# not sure why, but Xapian seems to fallback to terms and
		# phrase searches still work
		delete $ibx->{search};
		my $mset = $ibx->search->query('"hello world"', {mset=>1});
		is($mset->size, 0, 'phrase search does not work on medium');
	}

	my $mset = $ibx->search->query('hello world', {mset=>1});
	isnt($mset->size, 0, "normal search works on indexlevel=medium");
	for (<"$xap/*/*">) { $sizes{$ibx->{indexlevel}} += -s _ if -f $_ }
	ok($sizes{full} > $sizes{medium}, 'medium is smaller than full');


	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$mainrepo/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	$config{indexlevel} = 'basic';
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing without msgmap');
	is_deeply(\@warn, [], 'no warnings');
	$im->done;
	ok(-d $xap, 'Xapian directories recreated');
	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	my $mset = $ibx->search->query('hello', {mset=>1});
	is($mset->size, 0, "search fails on indexlevel='basic'");
	for (<"$xap/*/*">) { $sizes{$ibx->{indexlevel}} += -s _ if -f $_ }
	ok($sizes{medium} > $sizes{basic}, 'basic is smaller than medium');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

done_testing();
