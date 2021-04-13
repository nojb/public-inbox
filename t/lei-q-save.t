#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
my $doc1 = eml_load('t/plack-qp.eml');
my $doc2 = eml_load('t/utf8.eml');
test_lei(sub {
	my $home = $ENV{HOME};
	lei_ok qw(import -q t/plack-qp.eml);
	lei_ok qw(q -q --save z:0..), '-o', "$home/md/";
	my %before = map { $_ => 1 } glob("$home/md/cur/*");
	is_deeply(eml_load((keys %before)[0]), $doc1, 'doc1 matches');

	my @s = glob("$home/.local/share/lei/saved-searches/md-*");
	is(scalar(@s), 1, 'got one saved search');

	# ensure "lei up" works, since it compliments "lei q --save"
	lei_ok qw(import t/utf8.eml);
	lei_ok qw(up), $s[0];
	my %after = map { $_ => 1 } glob("$home/md/cur/*");
	is(delete $after{(keys(%before))[0]}, 1, 'original message kept');
	is(scalar(keys %after), 1, 'one new message added');
	is_deeply(eml_load((keys %after)[0]), $doc2, 'doc2 matches');
});
done_testing;
