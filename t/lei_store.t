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
my $store_dir = "$home/sto";
local $ENV{GIT_COMMITTER_EMAIL} = 'lei@example.com';
local $ENV{GIT_COMMITTER_NAME} = 'lei user';
my $sto = PublicInbox::LeiStore->new($store_dir, { creat => 1 });
ok($sto, '->new');
my $smsg = $sto->add_eml(eml_load('t/data/0001.patch'));
like($smsg->{blob}, qr/\A[0-9a-f]+\z/, 'add returned OID');
my $eml = eml_load('t/data/0001.patch');
is($sto->add_eml($eml), undef, 'idempotent');
$sto->done;
{
	my $es = $sto->search;
	ok($es->can('isrch'), ref($es). ' can ->isrch (for SolverGit)');
	my $msgs = $es->over->query_xover(0, 1000);
	is(scalar(@$msgs), 1, 'one message');
	is($msgs->[0]->{blob}, $smsg->{blob}, 'blob matches');
	my $mset = $es->mset("mid:$msgs->[0]->{mid}");
	is($mset->size, 1, 'search works');
	is_deeply($es->mset_to_artnums($mset), [ $msgs->[0]->{num} ],
		'mset_to_artnums');
	my $mi = ($mset->items)[0];
	my @kw = PublicInbox::Search::xap_terms('K', $mi->get_document);
	is_deeply(\@kw, [], 'no flags');
}

for my $parallel (0, 1) {
	$sto->{priv_eidx}->{parallel} = $parallel;
	my $docids = $sto->set_eml_vmd($eml, { kw => [ qw(seen draft) ] });
	is(scalar @$docids, 1, 'set keywords on one doc');
	$sto->done;
	my @kw = $sto->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [qw(draft seen)], 'kw matches');

	$docids = $sto->add_eml_vmd($eml, {kw => [qw(seen draft)]});
	$sto->done;
	is(scalar @$docids, 1, 'idempotently added keywords to doc');
	@kw = $sto->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [qw(draft seen)], 'kw matches after noop');

	$docids = $sto->remove_eml_vmd($eml, {kw => [qw(seen draft)]});
	is(scalar @$docids, 1, 'removed from one doc');
	$sto->done;
	@kw = $sto->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [], 'kw matches after remove');

	$docids = $sto->remove_eml_vmd($eml, {kw=> [qw(answered)]});
	is(scalar @$docids, 1, 'removed from one doc (idempotently)');
	$sto->done;
	@kw = $sto->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [], 'kw matches after remove (idempotent)');

	$docids = $sto->add_eml_vmd($eml, {kw => [qw(answered)]});
	is(scalar @$docids, 1, 'added to empty doc');
	$sto->done;
	@kw = $sto->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, ['answered'], 'kw matches after add');

	$docids = $sto->set_eml_vmd($eml, { kw => [] });
	is(scalar @$docids, 1, 'set to clobber');
	$sto->done;
	@kw = $sto->search->msg_keywords($docids->[0]);
	is_deeply(\@kw, [], 'set clobbers all');

	my $set = eml_load('t/plack-qp.eml');
	$set->header_set('Message-ID', "<set\@$parallel>");
	my $ret = $sto->set_eml($set, { kw => [ 'seen' ] });
	is(ref $ret, 'PublicInbox::Smsg', 'initial returns smsg');
	my $ids = $sto->set_eml($set, { kw => [ 'seen' ] });
	is_deeply($ids, [ $ret->{num} ], 'set_eml idempotent');
	$ids = $sto->set_eml($set, { kw => [ qw(seen answered) ] });
	is_deeply($ids, [ $ret->{num} ], 'set_eml to change kw');
	$sto->done;
	@kw = $sto->search->msg_keywords($ids->[0]);
	is_deeply(\@kw, [qw(answered seen)], 'set changed kw');
}

SKIP: {
	require_mods(qw(Storable), 1);
	ok($sto->can('ipc_do'), 'ipc_do works if we have Storable');
	$eml->header_set('Message-ID', '<ipc-test@example>');
	my $pid = $sto->ipc_worker_spawn('lei-store');
	ok($pid > 0, 'got a worker');
	my $smsg = $sto->ipc_do('set_eml', $eml, { kw => [ qw(seen) ] });
	is(ref($smsg), 'PublicInbox::Smsg', 'set_eml works over ipc');
	my $ids = $sto->ipc_do('set_eml', $eml, { kw => [ qw(seen) ] });
	is_deeply($ids, [ $smsg->{num} ], 'docid returned');

	$eml->header_set('Message-ID');
	my $no_mid = $sto->ipc_do('set_eml', $eml, { kw => [ qw(seen) ] });
	my $wait = $sto->ipc_do('done');
	my @kw = $sto->search->msg_keywords($no_mid->{num});
	is_deeply(\@kw, [qw(seen)], 'ipc set changed kw');

	is(ref($smsg), 'PublicInbox::Smsg', 'no mid works ipc');
	$ids = $sto->ipc_do('set_eml', $eml, { kw => [ qw(seen) ] });
	is_deeply($ids, [ $no_mid->{num} ], 'docid returned w/o mid w/ ipc');
	$sto->ipc_do('done');
	$sto->ipc_worker_stop;
	$ids = $sto->ipc_do('set_eml', $eml, { kw => [ qw(seen answered) ] });
	is_deeply($ids, [ $no_mid->{num} ], 'docid returned w/o mid w/o ipc');
	$wait = $sto->ipc_do('done');

	my $lse = $sto->search;
	@kw = $lse->msg_keywords($no_mid->{num});
	is_deeply(\@kw, [qw(answered seen)], 'set changed kw w/o ipc');
	is($lse->kw_changed($eml, [qw(answered seen)]), 0,
		'kw_changed false when unchanged');
	is($lse->kw_changed($eml, [qw(answered seen flagged)]), 1,
		'kw_changed true when +flagged');
	is($lse->kw_changed(eml_load('t/plack-qp.eml'), ['seen']), undef,
		'kw_changed undef on unknown message');
}

SKIP: {
	require_mods(qw(HTTP::Date), 1);
	my $now = HTTP::Date::time2str(time);
	$now =~ s/GMT/+0000/ or xbail "no GMT in $now";
	my $eml = PublicInbox::Eml->new(<<"EOM");
Received: (listserv\@example.com) by example.com via listexpand
	id abcde (ORCPT <rfc822;u\@example.com>);
	$now;
Date: $now
Subject: timezone-dependent test

WHAT IS TIME ANYMORE?
EOM

	my $smsg = $sto->add_eml($eml);
	ok($smsg && $smsg->{blob}, 'recently received message');
	$sto->done;
	local $ENV{TZ} = 'GMT+5';
	my $lse = $sto->search;
	my $qstr = 'rt:1.hour.ago.. s:timezone';
	$lse->query_approxidate($lse->git, $qstr);
	my $mset = $lse->mset($qstr);
	is($mset->size, 1, 'rt:1.hour.ago.. works w/ local time');
}

done_testing;
