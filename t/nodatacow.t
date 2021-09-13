#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Temp 0.19;
use_ok 'PublicInbox::NDC_PP';

SKIP: {
	my $nr = 2;
	skip 'test is Linux-only', $nr if $^O ne 'linux';
	my $dir = $ENV{BTRFS_TESTDIR};
	skip 'BTRFS_TESTDIR not defined', $nr unless defined $dir;
	require_cmd('chattr', 1) or skip 'chattr(1) not installed', $nr;
	my $lsattr = require_cmd('lsattr', 1) or
		skip 'lsattr(1) not installed', $nr;
	my $tmp = File::Temp->newdir('nodatacow-XXXX', DIR => $dir);
	my $dn = $tmp->dirname;

	my $name = "$dn/pp.f";
	open my $fh, '>', $name or BAIL_OUT "open($name): $!";
	my $pp_sub = \&PublicInbox::NDC_PP::nodatacow_fd;
	$pp_sub->(fileno($fh));
	my $res = xqx([$lsattr, $name]);
	like($res, qr/C.*\Q$name\E/, "`C' attribute set on fd with pure Perl");

	$name = "$dn/pp.d";
	mkdir($name) or BAIL_OUT "mkdir($name) $!";
	PublicInbox::NDC_PP::nodatacow_dir($name);
	$res = xqx([$lsattr, '-d', $name]);
	like($res, qr/C.*\Q$name\E/, "`C' attribute set on dir with pure Perl");

	$name = "$dn/ic.f";
	my $ic_sub = \&PublicInbox::Spawn::nodatacow_fd;
	$pp_sub == $ic_sub and
		skip 'Inline::C or Linux kernel headers missing', 2;
	open $fh, '>', $name or BAIL_OUT "open($name): $!";
	$ic_sub->(fileno($fh));
	$res = xqx([$lsattr, $name]);
	like($res, qr/C.*\Q$name\E/, "`C' attribute set on fd with Inline::C");

	$name = "$dn/ic.d";
	mkdir($name) or BAIL_OUT "mkdir($name) $!";
	PublicInbox::Spawn::nodatacow_dir($name);
	$res = xqx([$lsattr, '-d', $name]);
	like($res, qr/C.*\Q$name\E/, "`C' attribute set on dir with Inline::C");
};

done_testing;
