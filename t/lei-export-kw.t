#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Copy qw(cp);
use File::Path qw(make_path);
require_mods(qw(lei -imapd Mail::IMAPClient));
my ($tmpdir, $for_destroy) = tmpdir;
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $expect = eml_load('t/data/0001.patch');
test_lei({ tmpdir => $tmpdir }, sub {
	my $home = $ENV{HOME};
	my $md = "$home/md";
	make_path("$md/new", "$md/cur", "$md/tmp");
	cp('t/data/0001.patch', "$md/new/y") or xbail "cp $md $!";
	cp('t/data/message_embed.eml', "$md/cur/x:2,S") or xbail "cp $md $!";
	lei_ok qw(index -q), $md;
	lei_ok qw(tag t/data/0001.patch +kw:seen);
	lei_ok qw(export-kw --all=local);
	ok(!-e "$md/new/y", 'original gone');
	is_deeply(eml_load("$md/cur/y:2,S"), $expect,
		"`seen' kw exported");

	lei_ok qw(tag t/data/0001.patch +kw:answered);
	lei_ok qw(export-kw --all=local);
	ok(!-e "$md/cur/y:2,S", 'seen-only file gone');
	is_deeply(eml_load("$md/cur/y:2,RS"), $expect, "`R' added");

	lei_ok qw(tag t/data/0001.patch -kw:answered -kw:seen);
	lei_ok qw(export-kw --mode=set --all=local);
	ok(!-e "$md/cur/y:2,RS", 'seen+answered file gone');
	is_deeply(eml_load("$md/cur/y:2,"), $expect, 'no keywords left');
});

done_testing;
