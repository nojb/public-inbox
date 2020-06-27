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
local $ENV{XDG_DATA_HOME} = "$tmpdir/data";
{
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
SKIP: {
	my $nproc = $ENV{TEST_STRESS_NPROC};
	skip 'TEST_STRESS_NPROC= not set', 1 unless $nproc;
	my $nr = $ENV{TEST_STRESS_NR} // 10000;
	diag "TEST_STRESS_NPROC=$nproc TEST_STRESS_NR=$nr";
	require POSIX;
	for my $n (1..$nproc) {
		defined(my $pid = fork) or BAIL_OUT "fork: $!";
		if ($pid == 0) {
			my $url = "imap://example.com/INBOX.$$";
			my $uidval = time;
			eval {
				my $itrk = PublicInbox::IMAPTracker->new($url);
				for my $uid (1..$nr) {
					$itrk->update_last($uidval, $uid);
					my ($uv, $u) = $itrk->get_last;
				}
			};
			warn "E: $n $$ - $@\n" if $@;
			POSIX::_exit($@ ? 1 : 0);
		}
	}
	while (1) {
		my $pid = waitpid(-1, 0);
		last if $pid < 0;
		is($?, 0, "$pid exited");
	}
}

done_testing;
