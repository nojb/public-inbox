#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use_ok 'PublicInbox::IdxStack';
my $oid_a = '03c21563cf15c241687966b5b2a3f37cdc193316';
my $oid_b = '963caad026055ab9bcbe3ee9550247f9d8840feb';
my $cmt_a = 'df8e4a0612545d53672036641e9f076efc94c2f6';
my $cmt_b = '3ba7c9fa4a083c439e768882c571c2026a981ca5';

my $stk = PublicInbox::IdxStack->new;
is($stk->read_prepare, $stk, 'nothing');
is($stk->num_records, 0, 'no records');
is($stk->pop_rec, undef, 'undef on empty');

$stk = PublicInbox::IdxStack->new;
$stk->push_rec('m', 1234, 5678, $oid_a, $cmt_a);
is($stk->read_prepare, $stk, 'read_prepare');
is($stk->num_records, 1, 'num_records');
is_deeply([$stk->pop_rec], ['m', 1234, 5678, $oid_a, $cmt_a], 'pop once');
is($stk->pop_rec, undef, 'undef on empty');

$stk = PublicInbox::IdxStack->new;
$stk->push_rec('m', 1234, 5678, $oid_a, $cmt_a);
$stk->push_rec('d', 1234, 5678, $oid_b, $cmt_b);
is($stk->read_prepare, $stk, 'read_prepare');
is($stk->num_records, 2, 'num_records');
is_deeply([$stk->pop_rec], ['d', 1234, 5678, $oid_b, $cmt_b], 'pop');
is_deeply([$stk->pop_rec], ['m', 1234, 5678, $oid_a, $cmt_a], 'pop-pop');
is($stk->pop_rec, undef, 'empty');

SKIP: {
	$stk = undef;
	my $nr = $ENV{TEST_GIT_LOG} or skip 'TEST_GIT_LOG unset', 3;
	open my $fh, '-|', qw(git log --pretty=tformat:%at.%ct.%H), "-$nr" or
		die "git log: $!";
	my @expect;
	while (<$fh>) {
		chomp;
		my ($at, $ct, $H) = split(/\./);
		$stk //= PublicInbox::IdxStack->new;
		# not bothering to parse blobs here, just using commit OID
		# as a blob OID since they're the same size + format
		$stk->push_rec('m', $at + 0, $ct + 0, $H, $H);
		push(@expect, [ 'm', $at, $ct, $H, $H ]);
	}
	$stk or skip('nothing from git log', 3);
	is($stk->read_prepare, $stk, 'read_prepare');
	is($stk->num_records, scalar(@expect), 'num_records matches expected');
	my @result;
	while (my @tmp = $stk->pop_rec) {
		unshift @result, \@tmp;
	}
	is_deeply(\@result, \@expect, 'results match expected');
}

done_testing;
