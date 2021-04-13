#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
test_lei(sub {
	my $home = $ENV{HOME};
	lei_ok qw(import t/plack-qp.eml);
	lei_ok qw(q --save z:0..), '-o', "$home/md/";
	my @s = glob("$home/.local/share/lei/saved-searches/md-*");
	is(scalar(@s), 1, 'got one saved search');
});
done_testing;
