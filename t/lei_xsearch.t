#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use List::Util qw(shuffle max);
use PublicInbox::TestCommon;
use PublicInbox::ExtSearchIdx;
use PublicInbox::Eml;
use PublicInbox::InboxWritable;
require_mods(qw(DBD::SQLite Search::Xapian));
require_git 2.6;
require_ok 'PublicInbox::LeiXSearch';
my ($home, $for_destroy) = tmpdir();
my @ibx;
for my $V (1..2) {
	for my $i (3..6) {
		my $ibx = PublicInbox::InboxWritable->new({
			inboxdir => "$home/v$V-$i",
			name => "test-v$V-$i",
			version => $V,
			indexlevel => 'medium',
			-primary_address => "v$V-$i\@example.com",
		}, { nproc => int(rand(8)) + 1 });
		push @ibx, $ibx;
		my $im = $ibx->importer(0);
		for my $j (0..9) {
			my $eml = PublicInbox::Eml->new(<<EOF);
From: x\@example.com
To: $ibx->{-primary_address}
Date: Fri, 02 Oct 1993 0$V:0$i:0$j +0000
Subject: v${V}i${i}j$j
Message-ID: <v${V}i${i}j$j\@example>

${V}er ${i}on j$j
EOF
			$im->add($eml);
		}
		$im->done;
	}
}
my $first = shift @ibx; is($first->{name}, 'test-v1-3', 'first plucked');
my $last = pop @ibx; is($last->{name}, 'test-v2-6', 'last plucked');
my $eidx = PublicInbox::ExtSearchIdx->new("$home/eidx");
$eidx->attach_inbox($first);
$eidx->attach_inbox($last);
$eidx->eidx_sync({fsync => 0});
my $es = PublicInbox::ExtSearch->new("$home/eidx");
my $lxs = PublicInbox::LeiXSearch->new;
for my $ibxish (shuffle($es, @ibx)) {
	$lxs->attach_external($ibxish);
}
my $nr = $lxs->xdb->get_doccount;
my $mset = $lxs->mset('d:19931002..19931003', { limit => $nr });
is($mset->size, $nr, 'got all messages');
my @msgs;
for my $mi ($mset->items) {
	if (my $smsg = $lxs->smsg_for($mi)) {
		push @msgs, $smsg;
	} else {
		diag "E: ${\$mi->get_docid} missing";
	}
}
is(scalar(@msgs), $nr, 'smsgs retrieved for all');

$mset = $lxs->recent(undef, { limit => 1 });
is($mset->size, 1, 'one result');
my $max = max(map { $_->{docid} } @msgs);
is($lxs->smsg_for(($mset->items)[0])->{docid}, $max,
	'got highest docid');

done_testing;
