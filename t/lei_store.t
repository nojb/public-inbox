#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
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
my $smsg = $lst->add_eml(eml_load('t/data/0001.patch'));
like($smsg->{blob}, qr/\A[0-9a-f]+\z/, 'add returned OID');
my $eml = eml_load('t/data/0001.patch');
is($lst->add_eml($eml), undef, 'idempotent');
$lst->done;
is_deeply([$lst->mbox_keywords($eml)], [], 'no keywords');
$eml->header_set('Status', 'RO');
is_deeply([$lst->mbox_keywords($eml)], ['seen'], 'seen extracted');
$eml->header_set('X-Status', 'A');
is_deeply([$lst->mbox_keywords($eml)], [qw(answered seen)],
	'seen+answered extracted');
$eml->header_set($_) for qw(Status X-Status);

is_deeply([$lst->maildir_keywords('/foo:2,')], [], 'Maildir no keywords');
is_deeply([$lst->maildir_keywords('/foo:2,S')], ['seen'], 'Maildir seen');
is_deeply([$lst->maildir_keywords('/foo:2,RS')], ['answered', 'seen'],
	'Maildir answered + seen');
is_deeply([$lst->maildir_keywords('/foo:2,RSZ')], ['answered', 'seen'],
	'Maildir answered + seen w/o Z');
{
	my $es = $lst->search;
	my $msgs = $es->over->query_xover(0, 1000);
	is(scalar(@$msgs), 1, 'one message');
	is($msgs->[0]->{blob}, $smsg->{blob}, 'blob matches');
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

	my $set = eml_load('t/plack-qp.eml');
	$set->header_set('Message-ID', "<set\@$parallel>");
	my $ret = $lst->set_eml($set, 'seen');
	is(ref $ret, 'PublicInbox::Smsg', 'initial returns smsg');
	my $ids = $lst->set_eml($set, qw(seen));
	is_deeply($ids, [ $ret->{num} ], 'set_eml idempotent');
	$ids = $lst->set_eml($set, qw(seen answered));
	is_deeply($ids, [ $ret->{num} ], 'set_eml to change kw');
	$lst->done;
	@kw = $lst->search->msg_keywords($ids->[0]);
	is_deeply(\@kw, [qw(answered seen)], 'set changed kw');
}

SKIP: {
	require_mods(qw(Storable), 1);
	ok($lst->can('ipc_do'), 'ipc_do works if we have Storable');
	$eml->header_set('Message-ID', '<ipc-test@example>');
	my $pid = $lst->ipc_worker_spawn('lei-store');
	ok($pid > 0, 'got a worker');
	my $smsg = $lst->ipc_do('set_eml', $eml, qw(seen));
	is(ref($smsg), 'PublicInbox::Smsg', 'set_eml works over ipc');
	my $ids = $lst->ipc_do('set_eml', $eml, qw(seen));
	is_deeply($ids, [ $smsg->{num} ], 'docid returned');

	$eml->header_set('Message-ID');
	my $no_mid = $lst->ipc_do('set_eml', $eml, qw(seen));
	my $wait = $lst->ipc_do('done');
	my @kw = $lst->search->msg_keywords($no_mid->{num});
	is_deeply(\@kw, [qw(seen)], 'ipc set changed kw');

	is(ref($smsg), 'PublicInbox::Smsg', 'no mid works ipc');
	$ids = $lst->ipc_do('set_eml', $eml, qw(seen));
	is_deeply($ids, [ $no_mid->{num} ], 'docid returned w/o mid w/ ipc');
	$lst->ipc_do('done');
	$lst->ipc_worker_stop;
	$ids = $lst->ipc_do('set_eml', $eml, qw(seen answered));
	is_deeply($ids, [ $no_mid->{num} ], 'docid returned w/o mid w/o ipc');
	$wait = $lst->ipc_do('done');
	@kw = $lst->search->msg_keywords($no_mid->{num});
	is_deeply(\@kw, [qw(answered seen)], 'set changed kw w/o ipc');
}

done_testing;