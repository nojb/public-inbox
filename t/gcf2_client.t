#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use PublicInbox::TestCommon;
use Test::More;
use Cwd qw(getcwd);
use PublicInbox::Import;

require_mods('PublicInbox::Gcf2');
use_ok 'PublicInbox::Gcf2Client';
my ($tmpdir, $for_destroy) = tmpdir();
PublicInbox::Import::init_bare($tmpdir);
my $fi_data = './t/git.fast-import-data';
my $rdr = {};
open $rdr->{0}, '<', $fi_data or BAIL_OUT $!;
xsys([qw(git fast-import --quiet)], { GIT_DIR => $tmpdir }, $rdr);
is($?, 0, 'fast-import succeeded');

my $tree = 'fdbc43725f21f485051c17463b50185f4c3cf88c';
my $called = 0;
{
	local $ENV{PATH} = getcwd()."/blib/script:$ENV{PATH}";
	my $gcf2c = PublicInbox::Gcf2Client->new;
	$gcf2c->add_git_dir($tmpdir);
	$gcf2c->cat_async($tree, sub {
		my ($bref, $oid, $type, $size, $arg) = @_;
		is($oid, $tree, 'got expected OID');
		is($size, 30, 'got expected length');
		is($type, 'tree', 'got tree type');
		is(length($$bref), 30, 'got a tree');
		is($arg, 'hi', 'arg passed');
		$called++;
	}, 'hi');
	my $trunc = substr($tree, 0, 39);
	$gcf2c->cat_async($trunc, sub {
		my ($bref, $oid, $type, $size, $arg) = @_;
		is(undef, $bref, 'missing bref is undef');
		is($oid, $trunc, 'truncated OID printed');
		is($type, 'missing', 'type is "missing"');
		is($size, undef, 'size is undef');
		is($arg, 'bye', 'arg passed when missing');
		$called++;
	}, 'bye');
}
is($called, 2, 'cat_async callbacks hit');
done_testing;
