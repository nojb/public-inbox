#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Smsg;
require_mods(qw(DBD::SQLite));
use_ok 'PublicInbox::LeiDedupe';
my $eml = eml_load('t/plack-qp.eml');
my $mid = $eml->header_raw('Message-ID');
my $different = eml_load('t/msg_iter-order.eml');
$different->header_set('Message-ID', $mid);
my $smsg = bless { ds => time }, 'PublicInbox::Smsg';
$smsg->populate($eml);
$smsg->{$_} //= '' for (qw(to cc references)) ;

my $check_storable = sub {
	my ($x) = @_;
	SKIP: {
		require_mods('Storable', 1);
		my $dup = Storable::thaw(Storable::freeze($x));
		is_deeply($dup, $x, "$x->[3] round-trips through storable");
	}
};

my $lei = { opt => { dedupe => 'none' } };
my $dd = PublicInbox::LeiDedupe->new($lei);
$check_storable->($dd);
$dd->prepare_dedupe;
ok(!$dd->is_dup($eml), '1st is_dup w/o dedupe');
ok(!$dd->is_dup($eml), '2nd is_dup w/o dedupe');
ok(!$dd->is_dup($different), 'different is_dup w/o dedupe');
ok(!$dd->is_smsg_dup($smsg), 'smsg dedupe none 1');
ok(!$dd->is_smsg_dup($smsg), 'smsg dedupe none 2');

for my $strat (undef, 'content') {
	$lei->{opt}->{dedupe} = $strat;
	$dd = PublicInbox::LeiDedupe->new($lei);
	$check_storable->($dd);
	$dd->prepare_dedupe;
	my $desc = $strat // 'default';
	ok(!$dd->is_dup($eml), "1st is_dup with $desc dedupe");
	ok($dd->is_dup($eml), "2nd seen with $desc dedupe");
	ok(!$dd->is_dup($different), "different is_dup with $desc dedupe");
	ok(!$dd->is_smsg_dup($smsg), "is_smsg_dup pass w/ $desc dedupe");
	ok($dd->is_smsg_dup($smsg), "is_smsg_dup reject w/ $desc dedupe");
}
$lei->{opt}->{dedupe} = 'bogus';
eval { PublicInbox::LeiDedupe->new($lei) };
like($@, qr/unsupported.*bogus/, 'died on bogus strategy');

$lei->{opt}->{dedupe} = 'mid';
$dd = PublicInbox::LeiDedupe->new($lei);
$check_storable->($dd);
$dd->prepare_dedupe;
ok(!$dd->is_dup($eml), '1st is_dup with mid dedupe');
ok($dd->is_dup($eml), '2nd seen with mid dedupe');
ok($dd->is_dup($different), 'different seen with mid dedupe');
ok(!$dd->is_smsg_dup($smsg), 'smsg mid dedupe pass');
ok($dd->is_smsg_dup($smsg), 'smsg mid dedupe reject');

$lei->{opt}->{dedupe} = 'oid';
$dd = PublicInbox::LeiDedupe->new($lei);
$check_storable->($dd);
$dd->prepare_dedupe;

# --augment won't have OIDs:
ok(!$dd->is_dup($eml), '1st is_dup with oid dedupe (augment)');
ok($dd->is_dup($eml), '2nd seen with oid dedupe (augment)');
ok(!$dd->is_dup($different), 'different is_dup with mid dedupe (augment)');
$different->header_set('Status', 'RO');
ok($dd->is_dup($different), 'different seen with oid dedupe Status removed');

$smsg = { blob => '01d' };
ok(!$dd->is_dup($eml, $smsg), '1st is_dup with oid dedupe');
ok($dd->is_dup($different, $smsg), 'different content ignored if oid matches');
$smsg->{blob} = uc($smsg->{blob});
ok($dd->is_dup($eml, $smsg), 'case insensitive oid comparison :P');
$smsg->{blob} = '01dbad';
ok(!$dd->is_dup($eml, $smsg), 'case insensitive oid comparison :P');

$smsg->{blob} = 'dead';
ok(!$dd->is_smsg_dup($smsg), 'smsg dedupe pass');
ok($dd->is_smsg_dup($smsg), 'smsg dedupe reject');

done_testing;
