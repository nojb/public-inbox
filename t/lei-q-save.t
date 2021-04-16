#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Smsg;
my $doc1 = eml_load('t/plack-qp.eml');
$doc1->header_set('Date', PublicInbox::Smsg::date({ds => time - (86400 * 5)}));
my $doc2 = eml_load('t/utf8.eml');
$doc2->header_set('Date', PublicInbox::Smsg::date({ds => time - (86400 * 4)}));
my $doc3 = eml_load('t/msg_iter-order.eml');
$doc3->header_set('Date', PublicInbox::Smsg::date({ds => time - (86400 * 4)}));

test_lei(sub {
	my $home = $ENV{HOME};
	my $in = $doc1->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok qw(q -q --save z:0.. d:last.week..), '-o', "$home/md/";
	my %before = map { $_ => 1 } glob("$home/md/cur/*");
	is_deeply(eml_load((keys %before)[0]), $doc1, 'doc1 matches');

	my @s = glob("$home/.local/share/lei/saved-searches/md-*");
	is(scalar(@s), 1, 'got one saved search');
	my $cfg = PublicInbox::Config->new("$s[0]/lei.saved-search");
	is_deeply($cfg->{'lei.q'}, ['z:0..', 'd:last.week..'],
		'store relative time, not parsed (absolute) timestamp');

	# ensure "lei up" works, since it compliments "lei q --save"
	$in = $doc2->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok qw(up -q), $s[0];
	my %after = map { $_ => 1 } glob("$home/md/cur/*");
	is(delete $after{(keys(%before))[0]}, 1, 'original message kept');
	is(scalar(keys %after), 1, 'one new message added');
	is_deeply(eml_load((keys %after)[0]), $doc2, 'doc2 matches');

	# check stdin
	lei_ok [qw(q --save - -o), "mboxcl2:mbcl2" ],
		undef, { -C => $home, %$lei_opt, 0 => \'d:last.week..'};
	@s = glob("$home/.local/share/lei/saved-searches/mbcl2-*");
	$cfg = PublicInbox::Config->new("$s[0]/lei.saved-search");
	is_deeply $cfg->{'lei.q'}, 'd:last.week..',
		'q --stdin stores relative time';
	my $size = -s "$home/mbcl2";
	ok(defined($size) && $size > 0, 'results written');
	lei_ok([qw(up mbcl2)], undef, { -C => $home, %$lei_opt });
	is(-s "$home/mbcl2", $size, 'size unchanged on noop up');

	$in = $doc3->as_string;
	lei_ok [qw(import -q -F eml -)], undef, { 0 => \$in, %$lei_opt };
	lei_ok([qw(up mbcl2)], undef, { -C => $home, %$lei_opt });
	ok(-s "$home/mbcl2" > $size, 'size increased after up');
});
done_testing;
