#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use Socket qw(AF_UNIX SOCK_STREAM MSG_EOR);
pipe(my ($r, $w)) or BAIL_OUT;
my ($send, $recv);
require_ok 'PublicInbox::Spawn';
my $SOCK_SEQPACKET = eval { Socket::SOCK_SEQPACKET() } // undef;
use Time::HiRes qw(usleep);

my $do_test = sub { SKIP: {
	my ($type, $flag, $desc) = @_;
	defined $type or skip 'SOCK_SEQPACKET missing', 7;
	my ($s1, $s2);
	my $src = 'some payload' x 40;
	socketpair($s1, $s2, AF_UNIX, $type, 0) or BAIL_OUT $!;
	my $sfds = [ fileno($r), fileno($w), fileno($s1) ];
	$send->($s1, $sfds, $src, $flag);
	my (@fds) = $recv->($s2, my $buf, length($src) + 1);
	is($buf, $src, 'got buffer payload '.$desc);
	my ($r1, $w1, $s1a);
	my $opens = sub {
		ok(open($r1, '<&=', $fds[0]), 'opened received $r');
		ok(open($w1, '>&=', $fds[1]), 'opened received $w');
		ok(open($s1a, '+>&=', $fds[2]), 'opened received $s1');
	};
	$opens->();
	my @exp = stat $r;
	my @cur = stat $r1;
	is("$exp[0]\0$exp[1]", "$cur[0]\0$cur[1]", '$r dev/ino matches');
	@exp = stat $w;
	@cur = stat $w1;
	is("$exp[0]\0$exp[1]", "$cur[0]\0$cur[1]", '$w dev/ino matches');
	@exp = stat $s1;
	@cur = stat $s1a;
	is("$exp[0]\0$exp[1]", "$cur[0]\0$cur[1]", '$s1 dev/ino matches');
	if (defined($SOCK_SEQPACKET) && $type == $SOCK_SEQPACKET) {
		$r1 = $w1 = $s1a = undef;
		$src = (',' x 1023) . '-' .('.' x 1024);
		$send->($s1, $sfds, $src, $flag);
		(@fds) = $recv->($s2, $buf, 1024);
		is($buf, (',' x 1023) . '-', 'silently truncated buf');
		$opens->();
		$r1 = $w1 = $s1a = undef;

		$s2->blocking(0);
		@fds = $recv->($s2, $buf, length($src) + 1);
		ok($!{EAGAIN}, "EAGAIN set by ($desc)");
		is_deeply(\@fds, [ undef ], "EAGAIN $desc");
		$s2->blocking(1);

		if ($ENV{TEST_ALRM}) {
			my $alrm = 0;
			local $SIG{ALRM} = sub { $alrm++ };
			my $tgt = $$;
			my $pid = fork // xbail "fork: $!";
			if ($pid == 0) {
				# need to loop since Perl signals are racy
				# (the interpreter doesn't self-pipe)
				while (usleep(1000)) {
					kill 'ALRM', $tgt;
				}
			}
			@fds = $recv->($s2, $buf, length($src) + 1);
			ok($!{EINTR}, "EINTR set by ($desc)");
			kill('KILL', $pid);
			waitpid($pid, 0);
			is_deeply(\@fds, [ undef ], "EINTR $desc");
			ok($alrm, 'SIGALRM hit');
		}

		close $s1;
		@fds = $recv->($s2, $buf, length($src) + 1);
		is_deeply(\@fds, [], "no FDs on EOF $desc");
		is($buf, '', "buffer cleared on EOF ($desc)");

		socketpair($s1, $s2, AF_UNIX, $type, 0) or BAIL_OUT $!;
		$s1->blocking(0);
		my $nsent = 0;
		while (defined(my $n = $send->($s1, $sfds, $src, $flag))) {
			$nsent += $n;
			fail "sent 0 bytes" if $n == 0;
		}
		ok($!{EAGAIN} || $!{ETOOMANYREFS},
			"hit EAGAIN || ETOOMANYREFS on send $desc") or
			diag "send failed with: $!";
		ok($nsent > 0, 'sent some bytes');

		socketpair($s1, $s2, AF_UNIX, $type, 0) or BAIL_OUT $!;
		is($send->($s1, [], $src, $flag), length($src), 'sent w/o FDs');
		$buf = 'nope';
		@fds = $recv->($s2, $buf, length($src));
		is(scalar(@fds), 0, 'no FDs received');
		is($buf, $src, 'recv w/o FDs');

		my $nr = 2 * 1024 * 1024;
		while (1) {
			vec(my $vec = '', $nr * 8 - 1, 1) = 1;
			my $n = $send->($s1, [], $vec, $flag);
			if (defined($n)) {
				$n == length($vec) or
					fail "short send: $n != ".length($vec);
				diag "sent $nr, retrying with more";
				$nr += 2 * 1024 * 1024;
			} else {
				ok($!{EMSGSIZE} || $!{ENOBUFS},
					'got EMSGSIZE or ENOBUFS') or
					diag "$nr bytes fails with: $!";
				last;
			}
		}
	}
} };

my $send_ic = PublicInbox::Spawn->can('send_cmd4');
my $recv_ic = PublicInbox::Spawn->can('recv_cmd4');
SKIP: {
	($send_ic && $recv_ic) or skip 'Inline::C not installed/enabled', 12;
	$send = $send_ic;
	$recv = $recv_ic;
	$do_test->(SOCK_STREAM, 0, 'Inline::C stream');
	$do_test->($SOCK_SEQPACKET, MSG_EOR, 'Inline::C seqpacket');
}

SKIP: {
	require_mods('Socket::MsgHdr', 13);
	require_ok 'PublicInbox::CmdIPC4';
	$send = PublicInbox::CmdIPC4->can('send_cmd4');
	$recv = PublicInbox::CmdIPC4->can('recv_cmd4');
	$do_test->(SOCK_STREAM, 0, 'MsgHdr stream');
	$do_test->($SOCK_SEQPACKET, MSG_EOR, 'MsgHdr seqpacket');
	SKIP: {
		($send_ic && $recv_ic) or
			skip 'Inline::C not installed/enabled', 12;
		$recv = $recv_ic;
		$do_test->(SOCK_STREAM, 0, 'Inline::C -> MsgHdr stream');
		$do_test->($SOCK_SEQPACKET, 0, 'Inline::C -> MsgHdr seqpacket');
	}
}

done_testing;
