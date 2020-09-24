#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Inbox;
use List::Util qw(max);
use Benchmark qw(:all :hireswallclock);
use PublicInbox::Spawn qw(popen_rd);
use Carp ();
require_git(2.19); # for --unordered
my $inboxdir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;
my $ibx = PublicInbox::Inbox->new({ inboxdir => $inboxdir, name => 'x' });
my $git = $ibx->git;
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects --unordered);
my $fh = $git->popen(@cat);
my $cat_cb = sub {
	my ($bref, $oid, $type, $size, $check) = @_;
	my $orig = $$bref;
	my $copy = PublicInbox::Eml->new($bref)->as_string;
	++$check->[$orig eq $copy ? 0 : 1];
};

my $n = 0;
my $check = [ 0, 0 ]; # [ eql, neq ]
my $t = timeit(1, sub {
	my ($blob, $type);
	while (<$fh>) {
		($blob, $type) = split / /;
		next if $type ne 'blob';
		$git->cat_async($blob, $cat_cb, $check);
		if ((++$n % 8192) == 0) {
			diag "n=$n eql=$check->[0] neq=$check->[1]";
		}
	}
	$git->cat_async_wait;
});
is($check->[0], $n, 'all messages round tripped');
is($check->[1], 0, 'no messages failed to round trip');
done_testing;
