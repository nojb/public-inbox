#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite Search::Xapian));
require_git 2.6;
require_ok 'PublicInbox::LeiStore';
require_ok 'PublicInbox::ExtSearch';
my ($home, $for_destroy) = tmpdir();
my $opt = { 1 => \(my $out = ''), 2 => \(my $err = '') };
my $store_dir = "$home/lst";
my $lst = PublicInbox::LeiStore->new($store_dir, { creat => 1 });
ok($lst, '->new');
my $oid = $lst->add_eml(eml_load('t/data/0001.patch'));
like($oid, qr/\A[0-9a-f]+\z/, 'add returned OID');
my $eml = eml_load('t/data/0001.patch');
is($lst->add_eml($eml), undef, 'idempotent');
$lst->done;
{
	my $es = $lst->search;
	my $msgs = $es->over->query_xover(0, 1000);
	is(scalar(@$msgs), 1, 'one message');
	is($msgs->[0]->{blob}, $oid, 'blob matches');
	my $mset = $es->mset("mid:$msgs->[0]->{mid}");
	is($mset->size, 1, 'search works');
	is_deeply($es->mset_to_artnums($mset), [ $msgs->[0]->{num} ],
		'mset_to_artnums');
	my @kw = $es->msg_keywords(($mset->items)[0]);
	is_deeply(\@kw, [], 'no flags');
}

for my $parallel (0, 1) {
	$lst->{priv_eidx}->{parallel} = $parallel;
	my $docids = $lst->set_eml_keywords($eml, qw(seen draft));
	is(scalar @$docids, 1, 'set keywords on one doc');
	$lst->done;
	my @kw = $lst->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [qw(draft seen)], 'kw matches');

	$docids = $lst->add_eml_keywords($eml, qw(seen draft));
	$lst->done;
	is(scalar @$docids, 1, 'idempotently added keywords to doc');
	@kw = $lst->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [qw(draft seen)], 'kw matches after noop');

	$docids = $lst->remove_eml_keywords($eml, qw(seen draft));
	is(scalar @$docids, 1, 'removed from one doc');
	$lst->done;
	@kw = $lst->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [], 'kw matches after remove');

	$docids = $lst->remove_eml_keywords($eml, qw(answered));
	is(scalar @$docids, 1, 'removed from one doc (idempotently)');
	$lst->done;
	@kw = $lst->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [], 'kw matches after remove (idempotent)');

	$docids = $lst->add_eml_keywords($eml, qw(answered));
	is(scalar @$docids, 1, 'added to empty doc');
	$lst->done;
	@kw = $lst->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, ['answered'], 'kw matches after add');

	$docids = $lst->set_eml_keywords($eml);
	is(scalar @$docids, 1, 'set to clobber');
	$lst->done;
	@kw = $lst->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [], 'set clobbers all');
}

done_testing;
