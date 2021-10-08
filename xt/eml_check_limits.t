#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Inbox;
use List::Util qw(max);
use Benchmark qw(:all :hireswallclock);
use PublicInbox::Spawn qw(popen_rd);
use Carp ();
require_git(2.19); # for --unordered
require_mods(qw(BSD::Resource));
BSD::Resource->import(qw(getrusage));
my $cls = $ENV{TEST_CLASS};
if ($cls) {
	diag "TEST_CLASS=$cls";
	require_mods($cls);
}
$cls //= 'PublicInbox::Eml';
my $inboxdir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;
local $PublicInbox::Eml::mime_nesting_limit = 0x7fffffff;
local $PublicInbox::Eml::mime_parts_limit = 0x7fffffff;
local $PublicInbox::Eml::header_size_limit = 0x7fffffff;
my $ibx = PublicInbox::Inbox->new({ inboxdir => $inboxdir, name => 'x' });
my $git = $ibx->git;
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects --unordered);
my $fh = $git->popen(@cat);
my ($m, $n);
my $max_nest = [ 0, '' ]; # [ bytes, blob oid ]
my $max_idx = [ 0, '' ];
my $max_parts = [ 0, '' ];
my $max_size = [ 0, '' ];
my $max_hdr = [ 0, '' ];
my $info = [ 0, '' ];
my $each_part_cb = sub {
	my ($p) = @_;
	my ($part, $depth, $idx) = @$p;
	$max_nest = [ $depth, $info->[1] ] if $depth > $max_nest->[0];
	my $max = max(split(/\./, $idx));
	$max_idx = [ $max, $info->[1] ] if $max > $max_idx->[0];
	++$info->[0];
};

my ($bref, $oid, $size);
local $SIG{__WARN__} = sub { diag "$inboxdir $oid ", @_ };
my $cat_cb = sub {
	($bref, $oid, undef, $size) = @_;
	++$m;
	$info = [ 0, $oid ];
	my $eml = $cls->new($bref);
	my $hdr_len = length($eml->header_obj->as_string);
	$max_hdr = [ $hdr_len, $oid ] if $hdr_len > $max_hdr->[0];
	$eml->each_part($each_part_cb, $info, 1);
	$max_parts = $info if $info->[0] > $max_parts->[0];
	$max_size = [ $size, $oid ] if $size > $max_size->[0];
};

my $t = timeit(1, sub {
	my ($blob, $type);
	while (<$fh>) {
		($blob, $type) = split / /;
		next if $type ne 'blob';
		++$n;
		$git->cat_async($blob, $cat_cb);
	}
	$git->async_wait_all;
});
is($m, $n, 'scanned all messages');
diag "$$ $inboxdir took ".timestr($t)." for $n <=> $m messages";
diag "$$ max_nest $max_nest->[0] @ $max_nest->[1]";
diag "$$ max_idx $max_idx->[0] @ $max_idx->[1]";
diag "$$ max_parts $max_parts->[0] @ $max_parts->[1]";
diag "$$ max_size $max_size->[0] @ $max_size->[1]";
diag "$$ max_hdr $max_hdr->[0] @ $max_hdr->[1]";
diag "$$ RSS ".getrusage()->maxrss. ' k';
done_testing;
