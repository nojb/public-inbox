#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::Syscall', 'rename_noreplace';
my ($tmpdir, $for_destroy) = tmpdir;

open my $fh, '>', "$tmpdir/a" or xbail $!;
my @sa = stat($fh);
is(rename_noreplace("$tmpdir/a", "$tmpdir/b"), 1, 'rename_noreplace');
my @sb = stat("$tmpdir/b");
ok(scalar(@sb), 'new file exists');
ok(!-e "$tmpdir/a", 'original gone');
is("@sa[0,1]", "@sb[0,1]", 'same st_dev + st_ino');

is(rename_noreplace("$tmpdir/a", "$tmpdir/c"), undef, 'undef on ENOENT');
ok($!{ENOENT}, 'ENOENT set when missing');

open $fh, '>', "$tmpdir/a" or xbail $!;
is(rename_noreplace("$tmpdir/a", "$tmpdir/b"), undef, 'undef on EEXIST');
ok($!{EEXIST}, 'EEXIST set when missing');
is_deeply([stat("$tmpdir/b")], \@sb, 'target unchanged on EEXIST');

done_testing;
