#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use File::Temp qw(tempfile);
use PublicInbox::TestCommon;
use PublicInbox::Spawn qw(which);
use_ok 'PublicInbox::NDC_PP';

SKIP: {
	my $nr = 2;
	skip 'test is Linux-only', $nr if $^O ne 'linux';
	my $dir = $ENV{BTRFS_TESTDIR};
	skip 'BTRFS_TESTDIR not defined', $nr unless defined $dir;
	skip 'chattr(1) not installed', $nr unless which('chattr');
	my $lsattr = which('lsattr') or skip 'lsattr(1) not installed', $nr;
	my ($fh, $name) = tempfile(DIR => $dir, UNLINK => 1);
	BAIL_OUT "tempfile: $!" unless $fh && defined($name);
	my $pp_sub = \&PublicInbox::NDC_PP::set_nodatacow;
	$pp_sub->(fileno($fh));
	my $res = xqx([$lsattr, $name]);
	like($res, qr/C/, "`C' attribute set with pure Perl");

	my $ic_sub = \&PublicInbox::Spawn::set_nodatacow;
	$pp_sub == $ic_sub and
		skip 'Inline::C or Linux kernel headers missing', 1;
	($fh, $name) = tempfile(DIR => $dir, UNLINK => 1);
	$ic_sub->(fileno($fh));
	$res = xqx([$lsattr, $name]);
	like($res, qr/C/, "`C' attribute set with Inline::C");
};

done_testing;
