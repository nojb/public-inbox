#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use List::Util qw(shuffle);
use PublicInbox::TestCommon;
use PublicInbox::Eml;
require_mods(qw(DBD::SQLite Search::Xapian));
require PublicInbox::ExtSearchIdx;
require_git 2.6;
require_ok 'PublicInbox::LeiXSearch';
require_ok 'PublicInbox::LeiALE';
require_ok 'PublicInbox::LEI';
my ($home, $for_destroy) = tmpdir();
my @ibx;
for my $V (1..2) {
	for my $i (3..6) {
		push @ibx, create_inbox("v$V-$i", indexlevel => 'full',
					version => $V, sub {
			my ($im, $ibx) = @_;
			for my $j (0..9) {
				my $eml = PublicInbox::Eml->new(<<EOM);
From: x\@example.com
To: $ibx->{-primary_address}
Date: Fri, 02 Oct 1993 0$V:0$i:0$j +0000
Subject: v${V}i${i}j$j
Message-ID: <v${V}i${i}j$j\@example>

${V}er ${i}on j$j
EOM
				$im->add($eml) or BAIL_OUT '->add';
			}
		}); # create_inbox
	}
}
my $first = shift @ibx; is($first->{name}, 'v1-3', 'first plucked');
my $last = pop @ibx; is($last->{name}, 'v2-6', 'last plucked');
my $eidx = PublicInbox::ExtSearchIdx->new("$home/eidx");
$eidx->attach_inbox($first);
$eidx->attach_inbox($last);
$eidx->eidx_sync({fsync => 0});
my $es = PublicInbox::ExtSearch->new("$home/eidx");
my $lxs = PublicInbox::LeiXSearch->new;
for my $ibxish (shuffle($es, @ibx)) {
	$lxs->prepare_external($ibxish);
}
for my $loc ($lxs->locals) {
	$lxs->attach_external($loc);
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

$mset = $lxs->mset('z:1..', { relevance => -2, limit => 1 });
is($mset->size, 1, 'one result');

my @ibxish = $lxs->locals;
is(scalar(@ibxish), scalar(@ibx) + 1, 'got locals back');
is($lxs->search, $lxs, '->search works');
is($lxs->over, undef, '->over fails');

{
	$lxs = PublicInbox::LeiXSearch->new;
	my $v2ibx = create_inbox 'v2full', version => 2, sub {
		$_[0]->add(eml_load('t/plack-qp.eml'));
	};
	my $v1ibx = create_inbox 'v1medium', indexlevel => 'medium',
				tmpdir => "$home/v1tmp", sub {
		$_[0]->add(eml_load('t/utf8.eml'));
	};
	$lxs->prepare_external($v1ibx);
	$lxs->prepare_external($v2ibx);
	for my $loc ($lxs->locals) {
		$lxs->attach_external($loc);
	}
	my $mset = $lxs->mset('m:testmessage@example.com');
	is($mset->size, 1, 'got m: match on medium+full XSearch mix');
	my $mitem = ($mset->items)[0];
	my $smsg = $lxs->smsg_for($mitem) or BAIL_OUT 'smsg_for broken';

	my $ale = PublicInbox::LeiALE::_new("$home/ale");
	my $lei = bless {}, 'PublicInbox::LEI';
	$ale->refresh_externals($lxs, $lei);
	my $exp = [ $smsg->{blob}, 'blob', -s 't/utf8.eml' ];
	is_deeply([ $ale->git->check($smsg->{blob}) ], $exp, 'ale->git->check');

	$lxs = PublicInbox::LeiXSearch->new;
	$lxs->prepare_external($v2ibx);
	$ale->refresh_externals($lxs, $lei);
	is_deeply([ $ale->git->check($smsg->{blob}) ], $exp,
			'ale->git->check remembered inactive external');

	rename("$home/v1tmp", "$home/v1moved") or BAIL_OUT "rename: $!";
	$ale->refresh_externals($lxs, $lei);
	is($ale->git->check($smsg->{blob}), undef,
			'missing after directory gone');
}

done_testing;
