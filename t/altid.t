#!perl -w
# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::Msgmap';
use_ok 'PublicInbox::SearchIdx';
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";
my $alt_file = "$tmpdir/another-nntp.sqlite3";
my $altid = [ "serial:gmane:file=$alt_file" ];
my $ibx;

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 2);
	is($mm->mid_set(1234, 'a@example.com'), 1, 'mid_set once OK');
	ok(0 == $mm->mid_set(1234, 'a@example.com'), 'mid_set not idempotent');
	ok(0 == $mm->mid_set(1, 'a@example.com'), 'mid_set fails with dup MID');
}

{
	$ibx = create_inbox 'testbox', tmpdir => $git_dir, sub {
		my ($im) = @_;
		$im->add(PublicInbox::Eml->new(<<'EOF'));
From: a@example.com
To: b@example.com
Subject: boo!
Message-ID: <a@example.com>

hello world gmane:666
EOF
	};
	$ibx->{altid} = $altid;
	PublicInbox::SearchIdx->new($ibx, 1)->index_sync;
}

{
	my $mset = $ibx->search->mset("gmane:1234");
	my $msgs = $ibx->search->mset_to_smsg($ibx, $mset);
	$msgs = [ map { $_->{mid} } @$msgs ];
	is_deeply($msgs, ['a@example.com'], 'got one match');

	$mset = $ibx->search->mset('gmane:666');
	is($mset->size, 0, 'body did NOT match');
};

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 2);
	my ($min, $max) = $mm->minmax;
	my $num = $mm->mid_insert('b@example.com');
	ok($num > $max, 'auto-increment goes beyond mid_set');
}
done_testing;
