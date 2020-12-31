#!perl -w
use strict;
use v5.10.1;
use Test::More;
require_ok 'PublicInbox::OnDestroy';
my @x;
my $od = PublicInbox::OnDestroy->new(sub { push @x, 'hi' });
is_deeply(\@x, [], 'not called, yet');
undef $od;
is_deeply(\@x, [ 'hi' ], 'no args works');
$od = PublicInbox::OnDestroy->new(sub { $x[0] = $_[0] }, 'bye');
is_deeply(\@x, [ 'hi' ], 'nothing changed while alive');
undef $od;
is_deeply(\@x, [ 'bye' ], 'arg passed');
$od = PublicInbox::OnDestroy->new(sub { @x = @_ }, qw(x y));
undef $od;
is_deeply(\@x, [ 'x', 'y' ], '2 args passed');

open my $tmp, '+>>', undef or BAIL_OUT $!;
$tmp->autoflush(1);
$od = PublicInbox::OnDestroy->new(1, sub { print $tmp "$$ DESTROY\n" });
undef $od;
is(-s $tmp, 0, '$tmp is empty on pid mismatch');
$od = PublicInbox::OnDestroy->new($$, sub { $tmp = $$ });
undef $od;
is($tmp, $$, '$tmp set to $$ by callback');

if (my $nr = $ENV{TEST_LEAK_NR}) {
	for (0..$nr) {
		$od = PublicInbox::OnDestroy->new(sub { @x = @_ }, qw(x y));
	}
}

done_testing;
