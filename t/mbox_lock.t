#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use POSIX qw(_exit);
use PublicInbox::DS qw(now);
use Errno qw(EAGAIN);
use PublicInbox::OnDestroy;
use_ok 'PublicInbox::MboxLock';
my ($tmpdir, $for_destroy) = tmpdir();
my $f = "$tmpdir/f";
my $mbl = PublicInbox::MboxLock->acq($f, 1, ['dotlock']);
ok(-f "$f.lock", 'dotlock created');
undef $mbl;
ok(!-f "$f.lock", 'dotlock gone');
$mbl = PublicInbox::MboxLock->acq($f, 1, ['none']);
ok(!-f "$f.lock", 'no dotlock with none');
undef $mbl;
{
	opendir my $cur, '.' or BAIL_OUT $!;
	my $od = PublicInbox::OnDestroy->new(sub { chdir $cur });
	chdir $tmpdir or BAIL_OUT;
	my $abs = "$tmpdir/rel.lock";
	my $rel = PublicInbox::MboxLock->acq('rel', 1, ['dotlock']);
	chdir '/' or BAIL_OUT;
	ok(-f $abs, 'lock with abs path created');
	undef $rel;
	ok(!-f $abs, 'lock gone despite being in the wrong dir');
}

eval {
	PublicInbox::MboxLock->acq($f, 1, ['bogus']);
        fail "should not succeed with `bogus'";
};
ok($@, "fails on `bogus' lock method");
eval {
	PublicInbox::MboxLock->acq($f, 1, ['timeout=1']);
        fail "should not succeed with only timeout";
};
ok($@, "fails with only `timeout=' and no lock method");

my $defaults = PublicInbox::MboxLock->defaults;
is(ref($defaults), 'ARRAY', 'default lock methods');
my $test_rw_lock = sub {
	my ($func) = @_;
	my $m = ["$func,timeout=0.000001"];
	for my $i (1..2) {
		pipe(my ($r, $w)) or BAIL_OUT "pipe: $!";
		my $t0 = now;
		my $pid = fork // BAIL_OUT "fork $!";
		if ($pid == 0) {
			eval { PublicInbox::MboxLock->acq($f, 1, $m) };
			my $err = $@;
			syswrite $w, "E: $err";
			_exit($err ? 0 : 1);
		}
		undef $w;
		waitpid($pid, 0);
		is($?, 0, "$func r/w lock behaved as expected #$i");
		my $d = now - $t0;
		ok($d < 1, "$func r/w timeout #$i") or diag "elapsed=$d";
		my $err = do { local $/; <$r> };
		$! = EAGAIN;
		my $msg = "$!";
		like($err, qr/\Q$msg\E/, "got EAGAIN in child #$i");
	}
};

my $test_ro_lock = sub {
	my ($func) = @_;
	for my $i (1..2) {
		my $t0 = now;
		my $pid = fork // BAIL_OUT "fork $!";
		if ($pid == 0) {
			eval { PublicInbox::MboxLock->acq($f, 0, [ $func ]) };
			_exit($@ ? 1 : 0);
		}
		waitpid($pid, 0);
		is($?, 0, "$func ro lock behaved as expected #$i");
		my $d = now - $t0;
		ok($d < 1, "$func timeout respected #$i") or diag "elapsed=$d";
	}
};

SKIP: {
	grep(/fcntl/, @$defaults) or skip 'File::FcntlLock not available', 1;
	my $top = PublicInbox::MboxLock->acq($f, 1, $defaults);
	ok($top, 'fcntl lock acquired');
	$test_rw_lock->('fcntl');
	undef $top;
	$top = PublicInbox::MboxLock->acq($f, 0, $defaults);
	ok($top, 'fcntl read lock acquired');
	$test_ro_lock->('fcntl');
}
$mbl = PublicInbox::MboxLock->acq($f, 1, ['flock']);
ok($mbl, 'flock acquired');
$test_rw_lock->('flock');
undef $mbl;
$mbl = PublicInbox::MboxLock->acq($f, 0, ['flock']);
$test_ro_lock->('flock');

done_testing;
