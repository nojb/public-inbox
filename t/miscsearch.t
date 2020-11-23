#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::InboxWritable;
require_mods(qw(Search::Xapian DBD::SQLite));
use_ok 'PublicInbox::MiscSearch';
use_ok 'PublicInbox::MiscIdx';

my ($tmp, $for_destroy) = tmpdir();
my $eidx = { xpfx => "$tmp/eidx", -no_fsync => 1 }; # mock ExtSearchIdx
{
	mkdir "$tmp/v1" or BAIL_OUT "mkdir $!";
	open my $fh, '>', "$tmp/v1/description" or BAIL_OUT "open: $!";
	print $fh "Everything sucks this year\n" or BAIL_OUT "print $!";
	close $fh or BAIL_OUT "close $!";
}
{
	my $v1 = PublicInbox::InboxWritable->new({
		inboxdir => "$tmp/v1",
		name => 'hope',
		address => [ 'nope@example.com' ],
		indexlevel => 'basic',
		version => 1,
	});
	$v1->init_inbox;
	my $mi = PublicInbox::MiscIdx->new($eidx);
	$mi->begin_txn;
	$mi->index_ibx($v1);
	$mi->commit_txn;
}

my $ms = PublicInbox::MiscSearch->new("$tmp/eidx/misc");
my $mset = $ms->mset('"everything sucks today"');
is(scalar($mset->items), 0, 'no match on description phrase');

$mset = $ms->mset('"everything sucks this year"');
is(scalar($mset->items), 1, 'match phrase on description');

$mset = $ms->mset('everything sucks');
is(scalar($mset->items), 1, 'match words in description');

$mset = $ms->mset('nope@example.com');
is(scalar($mset->items), 1, 'match full address');

$mset = $ms->mset('nope');
is(scalar($mset->items), 1, 'match partial address');

$mset = $ms->mset('hope');
is(scalar($mset->items), 1, 'match name');
my $mi = ($mset->items)[0];
my $doc = $mi->get_document;
is($doc->get_data, '{}', 'stored empty data');

done_testing;
