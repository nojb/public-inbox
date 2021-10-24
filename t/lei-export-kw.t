#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Copy qw(cp);
use File::Path qw(make_path);
require_mods(qw(lei)); # see lei-import-imap.t for IMAP tests
my ($tmpdir, $for_destroy) = tmpdir;
my $expect = eml_load('t/data/0001.patch');
my $do_export_kw = 1;
my $wait_for = sub {
	my ($f) = @_;
	lei_ok qw(export-kw --all=local) if $do_export_kw;
	my $x = $f;
	$x =~ s!\Q$tmpdir\E/!\$TMPDIR/!;
	for (0..10) {
		last if -f $f;
		diag "tick #$_ $x";
		tick(0.1);
	}
	ok(-f $f, "$x exists") or xbail;
};

test_lei({ tmpdir => $tmpdir }, sub {
	my $home = $ENV{HOME};
	my $md = "$home/md";
	my $f;
	make_path("$md/new", "$md/cur", "$md/tmp");
	cp('t/data/0001.patch', "$md/new/y") or xbail "cp $md $!";
	cp('t/data/message_embed.eml', "$md/cur/x:2,S") or xbail "cp $md $!";
	lei_ok qw(index), $md;
	lei_ok qw(tag t/data/0001.patch +kw:seen);
	$wait_for->($f = "$md/cur/y:2,S");
	ok(!-e "$md/new/y", 'original gone') or
		diag explain([glob("$md/*/*")]);
	is_deeply(eml_load($f), $expect, "`seen' kw exported");

	lei_ok qw(tag t/data/0001.patch +kw:answered);
	$wait_for->($f = "$md/cur/y:2,RS");
	ok(!-e "$md/cur/y:2,S", 'seen-only file gone') or
		diag explain([glob("$md/*/*")]);
	is_deeply(eml_load($f), $expect, "`R' added");

	lei_ok qw(tag t/data/0001.patch -kw:answered -kw:seen);
	$wait_for->($f = "$md/cur/y:2,");
	ok(!-e "$md/cur/y:2,RS", 'seen+answered file gone') or
		diag explain([glob("$md/*/*")]);
	is_deeply(eml_load($f), $expect, 'no keywords left');
});

done_testing;
