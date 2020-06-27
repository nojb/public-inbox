# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use strict;
use PublicInbox::TestCommon;
require_mods 'DBD::SQLite';
use_ok 'PublicInbox::IMAPTracker';
my ($tmpdir, $for_destroy) = tmpdir();
mkdir "$tmpdir/old" or die "mkdir $tmpdir/old: $!";
my $old = "$tmpdir/old/imap.sqlite3";
my $cur = "$tmpdir/data/public-inbox/imap.sqlite3";
{
	local $ENV{XDG_DATA_HOME} = "$tmpdir/data";
	local $ENV{PI_DIR} = "$tmpdir/old";

	my $tracker = PublicInbox::IMAPTracker->new;
	ok(-f $cur, '->new creates file');
	$tracker = undef;
	ok(-f $cur, 'file persists after DESTROY');
	link $cur, $old or die "link $cur => $old: $!";
	unlink $cur or die "unlink $cur: $!";
	$tracker = PublicInbox::IMAPTracker->new;
	ok(!-f $cur, '->new does not create new file if old is present');
}

done_testing;
