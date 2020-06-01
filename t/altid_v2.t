# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
use PublicInbox::TestCommon;
require_git(2.6);
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::V2Writable';
use_ok 'PublicInbox::Inbox';
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = "$tmpdir/inbox";
my $full = "$tmpdir/inbox/another-nntp.sqlite3";
my $altid = [ 'serial:gmane:file=another-nntp.sqlite3' ];

{
	ok(mkdir($inboxdir), 'created repo for msgmap');
	my $mm = PublicInbox::Msgmap->new_file($full, 1);
	is($mm->mid_set(1234, 'a@example.com'), 1, 'mid_set once OK');
	ok(0 == $mm->mid_set(1234, 'a@example.com'), 'mid_set not idempotent');
	ok(0 == $mm->mid_set(1, 'a@example.com'), 'mid_set fails with dup MID');
}

my $ibx = {
	inboxdir => $inboxdir,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
	altid => $altid,
};
$ibx = PublicInbox::Inbox->new($ibx);
my $v2w = PublicInbox::V2Writable->new($ibx, 1);
$v2w->add(PublicInbox::Eml->new(<<'EOF'));
From: a@example.com
To: b@example.com
Subject: boo!
Message-ID: <a@example.com>

hello world gmane:666
EOF
$v2w->done;

my $msgs = $ibx->search->reopen->query("gmane:1234");
$msgs = [ map { $_->{mid} } @$msgs ];
is_deeply($msgs, ['a@example.com'], 'got one match');
$msgs = $ibx->search->query("gmane:666");
is_deeply([], $msgs, 'body did NOT match');

done_testing();

1;
