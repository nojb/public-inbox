# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
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
use_ok 'PublicInbox::V2Writable';
my ($inboxdir, $for_destroy) = tmpdir();
my $ibx_config = {
	inboxdir => $inboxdir,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
	indexlevel => 'full',
};
my $agpl = eval {
	open my $fh, '<', 'COPYING' or die "can't open COPYING: $!";
	local $/;
	<$fh>;
};
$agpl or die "AGPL or die :P\n";
my $phrase = q("defending all users' freedom");
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => $agpl,
);
my $minmax;
my $msgmap;
my ($mark1, $mark2, $mark3, $mark4);
{
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx, {nproc => 1});
	my $im0 = $im->importer();
	foreach my $i (1..10) {
		$mime->header_set('Message-Id', "<$i\@example.com>");
		ok($im->add($mime), "message $i added");
		if ($i == 4) {
			$mark1 = $im0->get_mark($im0->{tip});
			$im->remove($mime);
			$mark2 = $im0->get_mark($im0->{tip});
		}
	}

	if ('test remove later') {
		$mark3 = $im0->get_mark($im0->{tip});
		$mime->header_set('Message-Id', "<5\@example.com>");
		$im->remove($mime);
		$mark4 = $im0->get_mark($im0->{tip});
	}

	$im->done;
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
	my $im = PublicInbox::V2Writable->new($ibx, 1);
	eval { $im->index_sync({reindex => 1}) };
	is($@, '', 'no error from reindexing');
	$im->done;

	delete $ibx->{mm};
	is_deeply([ $ibx->mm->minmax ], $minmax, 'minmax unchanged');
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

my $xap = "$inboxdir/xap".PublicInbox::Search::SCHEMA_VERSION();
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
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/msgmap.sqlite3", 'remove msgmap');
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
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

my %sizes;
ok(unlink "$inboxdir/msgmap.sqlite3", 'remove msgmap');
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
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');
	my $mset = $ibx->search->query($phrase, {mset=>1});
	isnt($mset->size, 0, "phrase search succeeds on indexlevel=full");
	for (<"$xap/*/*">) { $sizes{$ibx->{indexlevel}} += -s _ if -f $_ }

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/msgmap.sqlite3", 'remove msgmap');
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
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	if (0) {
		# not sure why, but Xapian seems to fallback to terms and
		# phrase searches still work
		delete $ibx->{search};
		my $mset = $ibx->search->query($phrase, {mset=>1});
		is($mset->size, 0, 'phrase search does not work on medium');
	}
	my $words = $phrase;
	$words =~ tr/"'//d;
	my $mset = $ibx->search->query($words, {mset=>1});
	isnt($mset->size, 0, "normal search works on indexlevel=medium");
	for (<"$xap/*/*">) { $sizes{$ibx->{indexlevel}} += -s _ if -f $_ }

	ok($sizes{full} > $sizes{medium}, 'medium is smaller than full');


	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}

ok(unlink "$inboxdir/msgmap.sqlite3", 'remove msgmap');
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
	is($ibx->mm->num_highwater, 10, 'num_highwater as expected');

	isnt($ibx->search, 'no search for basic');

	for (<"$xap/*/*">) { $sizes{$ibx->{indexlevel}} += -s _ if -f $_ }
	ok($sizes{medium} > $sizes{basic}, 'basic is smaller than medium');

	my ($min, $max) = $ibx->mm->minmax;
	is_deeply($ibx->mm->msg_range(\$min, $max), $msgmap, 'msgmap unchanged');
}


# An incremental indexing test
ok(unlink "$inboxdir/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	# mark1 4 simple additions in the same index_sync
	$ibx->{ref_head} = $mark1;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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
	# mark2 A delete separated from an add in the same index_sync
	$ibx->{ref_head} = $mark2;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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
	# mark3 adds following the delete at mark2
	$ibx->{ref_head} = $mark3;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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
	# mark4 A delete of an older message
	$ibx->{ref_head} = $mark4;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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
ok(unlink "$inboxdir/msgmap.sqlite3", 'remove msgmap');
remove_tree($xap);
ok(!-d $xap, 'Xapian directories removed again');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	my $ibx = PublicInbox::Inbox->new(\%config);
	# mark2 an add and it's delete in the same index_sync
	$ibx->{ref_head} = $mark2;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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
	# mark3 adds following the delete at mark2
	$ibx->{ref_head} = $mark3;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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
	# mark4 A delete of an older message
	$ibx->{ref_head} = $mark4;
	my $im = PublicInbox::V2Writable->new($ibx);
	eval { $im->index_sync() };
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

# A real example from linux-renesas-soc on lore where a 3-headed monster
# of a message has 3 sets of common headers.  Another normal message
# previously existed with a single Message-ID that conflicts with one
# of the Message-IDs in the 3-headed monster.
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my %config = %$ibx_config;
	$config{indexlevel} = 'medium';
	my $ibx = PublicInbox::Inbox->new(\%config);
	my $im = PublicInbox::V2Writable->new($ibx);
	my $m3 = PublicInbox::MIME->new(<<'EOF');
Date: Tue, 24 May 2016 14:34:22 -0700 (PDT)
Message-Id: <20160524.143422.552507610109476444.d@example.com>
To: t@example.com
Cc: c@example.com
Subject: Re: [PATCH v2 2/2] uno
From: <f@example.com>
In-Reply-To: <1463825855-7363-2-git-send-email-y@example.com>
References: <1463825855-7363-1-git-send-email-y@example.com>
	<1463825855-7363-2-git-send-email-y@example.com>
Date: Wed, 25 May 2016 10:01:51 +0900
From: h@example.com
To: g@example.com
Cc: m@example.com
Subject: Re: [PATCH] dos
Message-ID: <20160525010150.GD7292@example.com>
References: <1463498133-23918-1-git-send-email-g+r@example.com>
In-Reply-To: <1463498133-23918-1-git-send-email-g+r@example.com>
From: s@example.com
To: h@example.com
Cc: m@example.com
Subject: [PATCH 12/13] tres
Date: Wed, 01 Jun 2016 01:32:35 +0300
Message-ID: <1923946.Jvi0TDUXFC@wasted.example.com>
In-Reply-To: <13205049.n7pM8utpHF@wasted.example.com>
References: <13205049.n7pM8utpHF@wasted.example.com>

Somehow we got a message with 3 sets of headers into one
message, could've been something broken on the archiver side.
EOF

	my $m1 = PublicInbox::MIME->new(<<'EOF');
From: a@example.com
To: t@example.com
Subject: [PATCH 12/13]
Date: Wed, 01 Jun 2016 01:32:35 +0300
Message-ID: <1923946.Jvi0TDUXFC@wasted.example.com>
In-Reply-To: <13205049.n7pM8utpHF@wasted.example.com>
References: <13205049.n7pM8utpHF@wasted.example.com>

This is probably one of the original messages

EOF
	$im->add($m1);
	$im->add($m3);
	$im->done;
	remove_tree($xap);
	eval { $im->index_sync() };
	is($@, '', 'no error from initial indexing');
	is_deeply(\@warn, [], 'no warnings from initial index');
	eval { $im->index_sync({reindex=>1}) };
	is($@, '', 'no error from reindexing after reused Message-ID (x3)');
	is_deeply(\@warn, [], 'no warnings on reindex');

	my %uniq;
	for my $s (qw(uno dos tres)) {
		my $msgs = $ibx->search->query("s:$s");
		is(scalar(@$msgs), 1, "only one result for `$s'");
		$uniq{$msgs->[0]->{num}}++;
	}
	is_deeply([values %uniq], [3], 'search on different subjects');
}

done_testing();
