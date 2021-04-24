#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite));
require_ok 'PublicInbox::LeiMailSync';
my ($dir, $for_destroy) = tmpdir();
my $lms = PublicInbox::LeiMailSync->new("$dir/t.sqlite3");

$lms->lms_begin;
$lms->lms_commit;
my $ro = PublicInbox::LeiMailSync->new("$dir/t.sqlite3");
is_deeply([$ro->folders], [], 'no folders, yet');

my $imap = 'imaps://bob@[::1]/INBOX;UIDVALIDITY=9';
$lms->lms_begin;
is($lms->set_src('deadbeef', $imap, 1), 1, 'set IMAP once');
ok($lms->set_src('deadbeef', $imap, 1) == 0, 'set IMAP idempotently');
$lms->lms_commit;
is_deeply([$ro->folders], [$imap], 'IMAP folder added');
is_deeply([$ro->folders($imap)], [$imap], 'IMAP folder with full GLOB');
is_deeply([$ro->folders('imaps://bob@[::1]/INBOX')], [$imap],
		'IMAP folder with partial GLOB');

is_deeply($ro->locations_for('deadbeef'),
	{ $imap => [ 1 ] }, 'locations_for w/ imap');

my $maildir = 'maildir:/home/user/md';
my $fname = 'foo:2,S';
$lms->lms_begin;
ok($lms->set_src('deadbeef', $maildir, \$fname), 'set Maildir once');
ok($lms->set_src('deadbeef', $maildir, \$fname) == 0, 'set Maildir again');
$lms->lms_commit;
is_deeply($ro->locations_for('deadbeef'),
	{ $imap => [ 1 ], $maildir => [ $fname ] },
	'locations_for w/ maildir + imap');

is_deeply([sort($ro->folders)], [$imap, $maildir], 'both folders shown');
my @res;
$ro->each_src($maildir, sub {
	my ($oidbin, $id) = @_;
	push @res, [ unpack('H*', $oidbin), $id ];
});
is_deeply(\@res, [ ['deadbeef', \$fname] ], 'each_src works on Maildir');

@res = ();
$ro->each_src($imap, sub {
	my ($oidbin, $id) = @_;
	push @res, [ unpack('H*', $oidbin), $id ];
});
is_deeply(\@res, [ ['deadbeef', 1] ], 'each_src works on IMAP');

is_deeply($ro->location_stats($maildir), { 'name.count' => 1 },
	'Maildir location stats');
is_deeply($ro->location_stats($imap),
	{ 'uid.count' => 1, 'uid.max' => 1, 'uid.min' => 1 },
	'IMAP location stats');
$lms->lms_begin;
is($lms->clear_src($imap, 1), 1, 'clear_src on IMAP');
is($lms->clear_src($maildir, \$fname), 1, 'clear_src on Maildir');
ok($lms->clear_src($imap, 1) == 0, 'clear_src again on IMAP');
ok($lms->clear_src($maildir, \$fname) == 0, 'clear_src again on Maildir');
$lms->lms_commit;
is_deeply($ro->location_stats($maildir), {}, 'nothing left');

done_testing;
