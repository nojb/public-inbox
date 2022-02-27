#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use POSIX qw(WTERMSIG WIFSIGNALED SIGPIPE SIG_UNBLOCK SIG_SETMASK sigprocmask);
use PublicInbox::OnDestroy;

# undo systemd (and similar) blocking SIGPIPE, since lei expects to be run
# from an interactive terminal:
# https://public-inbox.org/meta/20220227080422.gyqowrxomzu6gyin@sourcephile.fr/
my $set = POSIX::SigSet->new;
my $old = POSIX::SigSet->new;
$set->emptyset or xbail "sigemptyset $!";
$old->emptyset or xbail "sigemptyset $!";
$set->addset(SIGPIPE);
sigprocmask(SIG_UNBLOCK, $set, $old) or xbail "SIG_UNBLOCK: $!";
my $cleanup = PublicInbox::OnDestroy->new($$, sub {
	sigprocmask(SIG_SETMASK, $old);
});

test_lei(sub {
	my $f = "$ENV{HOME}/big.eml";
	my $imported;
	for my $out ([], [qw(-f mboxcl2)], [qw(-f text)]) {
		pipe(my ($r, $w)) or BAIL_OUT $!;
		my $size = 65536;
		if ($^O eq 'linux' && fcntl($w, 1031, 4096)) {
			$size = 4096;
		}
		unless (-f $f) {
			open my $fh, '>', $f or xbail "open $f: $!";
			print $fh <<'EOM' or xbail;
From: big@example.com
Message-ID: <big@example.com>
EOM
			print $fh 'Subject:';
			print $fh (' '.('x' x 72)."\n") x (($size / 73) + 1);
			print $fh "\nbody\n";
			close $fh or xbail "close: $!";
		}

		lei_ok(qw(import), $f) if $imported++ == 0;
		open my $errfh, '+>>', "$ENV{HOME}/stderr.log" or xbail $!;
		my $opt = { run_mode => 0, 2 => $errfh, 1 => $w };
		my $cmd = [qw(lei q -q -t), @$out, 'z:1..'];
		my $tp = start_script($cmd, undef, $opt);
		close $w;
		vec(my $rvec = '', fileno($r), 1) = 1;
		if (!select($rvec, undef, undef, 30)) {
			seek($errfh, 0, 0) or xbail $!;
			my $s = do { local $/; <$errfh> };
			xbail "lei q had no output after 30s, stderr=$s";
		}
		is(sysread($r, my $buf, 1), 1, 'read one byte');
		close $r; # trigger SIGPIPE
		$tp->join;
		ok(WIFSIGNALED($?), "signaled @$out");
		is(WTERMSIG($?), SIGPIPE, "got SIGPIPE @$out");
		seek($errfh, 0, 0) or xbail $!;
		my $s = do { local $/; <$errfh> };
		is($s, '', "quiet after sigpipe @$out");
	}
});

done_testing;
