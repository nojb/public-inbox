# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::Msgmap';
use_ok 'PublicInbox::SearchIdx';
use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Inbox';
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";
my $alt_file = "$tmpdir/another-nntp.sqlite3";
my $altid = [ "serial:gmane:file=$alt_file" ];
my $ibx;

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 1);
	is($mm->mid_set(1234, 'a@example.com'), 1, 'mid_set once OK');
	ok(0 == $mm->mid_set(1234, 'a@example.com'), 'mid_set not idempotent');
	ok(0 == $mm->mid_set(1, 'a@example.com'), 'mid_set fails with dup MID');
}

{
	my $git = PublicInbox::Git->new($git_dir);
	my $im = PublicInbox::Import->new($git, 'testbox', 'test@example');
	$im->init_bare;
	$im->add(PublicInbox::Eml->new(<<'EOF'));
From: a@example.com
To: b@example.com
Subject: boo!
Message-ID: <a@example.com>

hello world gmane:666
EOF
	$im->done;
}
{
	$ibx = PublicInbox::Inbox->new({inboxdir => $git_dir});
	$ibx->{altid} = $altid;
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	$rw->index_sync;
}

{
	my $ro = PublicInbox::Search->new($ibx);
	my $msgs = $ro->query("gmane:1234");
	$msgs = [ map { $_->{mid} } @$msgs ];
	is_deeply($msgs, ['a@example.com'], 'got one match');

	$msgs = $ro->query("gmane:666");
	is_deeply([], $msgs, 'body did NOT match');
};

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 1);
	my ($min, $max) = $mm->minmax;
	my $num = $mm->mid_insert('b@example.com');
	ok($num > $max, 'auto-increment goes beyond mid_set');
}

done_testing();

1;
