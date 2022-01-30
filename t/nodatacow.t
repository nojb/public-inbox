#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Temp 0.19;
use_ok 'PublicInbox::Syscall';

# btrfs on Linux is copy-on-write (COW) by default.  As of Linux 5.7,
# this still leads to fragmentation for SQLite and Xapian files where
# random I/O happens, so we disable COW just for SQLite files and Xapian
# directories.  Disabling COW disables checksumming, so we only do this
# for regeneratable files, and not canonical git storage (git doesn't
# checksum refs, only data under $GIT_DIR/objects).

SKIP: {
	my $nr = 2;
	skip 'test is Linux-only', $nr if $^O ne 'linux';
	my $dir = $ENV{BTRFS_TESTDIR};
	skip 'BTRFS_TESTDIR not defined', $nr unless defined $dir;

	my $lsattr = require_cmd('lsattr', 1) or
		skip 'lsattr(1) not installed', $nr;

	my $tmp = File::Temp->newdir('nodatacow-XXXX', DIR => $dir);
	my $dn = $tmp->dirname;

	my $name = "$dn/pp.f";
	open my $fh, '>', $name or BAIL_OUT "open($name): $!";
	PublicInbox::Syscall::nodatacow_fh($fh);
	my $res = xqx([$lsattr, $name]);

	BAIL_OUT "lsattr(1) fails in $dir" if $?;
	like($res, qr/C.*\Q$name\E/, "`C' attribute set on fd with pure Perl");

	$name = "$dn/pp.d";
	mkdir($name) or BAIL_OUT "mkdir($name) $!";
	PublicInbox::Syscall::nodatacow_dir($name);
	$res = xqx([$lsattr, '-d', $name]);
	like($res, qr/C.*\Q$name\E/, "`C' attribute set on dir with pure Perl");
};

done_testing;
