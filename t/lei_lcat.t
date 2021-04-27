#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# unit test for "lei lcat" internals, see t/lei-lcat.t for functional test
use strict;
use v5.10.1;
use Test::More;
use_ok 'PublicInbox::LeiLcat';
my $cb = \&PublicInbox::LeiLcat::extract_1;
my $ck = sub {
	my ($txt, $exp, $t) = @_;
	my $lei = {};
	is($cb->($lei, $txt), $exp, $txt);
	($t ? is_deeply($lei, { mset_opt => { threads => 1 } }, "-t $exp")
		: is_deeply($lei, {}, "no -t for $exp")) or diag explain($lei);
};

for my $txt (qw(https://example.com/inbox/foo@bar/
		https://example.com/inbox/foo@bar
		https://example.com/inbox/foo@bar/raw
		id:foo@bar
		mid:foo@bar
		<foo@bar>
		<https://example.com/inbox/foo@bar>
		<https://example.com/inbox/foo@bar/raw>
		<https://example.com/inbox/foo@bar/>
		<nntp://example.com/foo@bar>)) {
	$ck->($txt, 'mid:foo@bar');
}

for my $txt (qw(https://example.com/inbox/foo@bar/T/
		https://example.com/inbox/foo@bar/t/
		https://example.com/inbox/foo@bar/t.mbox.gz
		<https://example.com/inbox/foo@bar/t.atom>
		<https://example.com/inbox/foo@bar/t/>)) {
	$ck->($txt, 'mid:foo@bar', '-t');
}

$ck->('https://example.com/x/foobar/T/', 'mid:foobar', '-t');
$ck->('https://example.com/x/foobar/raw', 'mid:foobar');
is($cb->(my $lei = {}, 'asdf'), undef, 'no Message-ID');
is($cb->($lei = {}, 'm:x'), 'm:x', 'bare m: accepted');

done_testing;
