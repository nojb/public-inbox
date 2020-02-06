# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use Test::More;
unless (eval { require IO::KQueue }) {
	my $m = $^O !~ /bsd/ ? 'DSKQXS is only for *BSD systems'
				: "no IO::KQueue, skipping $0: $@";
	plan skip_all => $m;
}

if ('ensure nested kqueue works for signalfd emulation') {
	require POSIX;
	my $new = POSIX::SigSet->new(POSIX::SIGHUP());
	my $old = POSIX::SigSet->new;
	my $hup = 0;
	local $SIG{HUP} = sub { $hup++ };
	POSIX::sigprocmask(POSIX::SIG_SETMASK(), $new, $old) or die;
	my $kqs = IO::KQueue->new or die;
	$kqs->EV_SET(POSIX::SIGHUP(), IO::KQueue::EVFILT_SIGNAL(),
			IO::KQueue::EV_ADD());
	kill('HUP', $$) or die;
	my @events = $kqs->kevent(3000);
	is(scalar(@events), 1, 'got one event');
	is($events[0]->[0], POSIX::SIGHUP(), 'got SIGHUP');
	my $parent = IO::KQueue->new or die;
	my $kqfd = $$kqs;
	$parent->EV_SET($kqfd, IO::KQueue::EVFILT_READ(), IO::KQueue::EV_ADD());
	kill('HUP', $$) or die;
	@events = $parent->kevent(3000);
	is(scalar(@events), 1, 'got one event');
	is($events[0]->[0], $kqfd, 'got kqfd');
	is($hup, 0, '$SIG{HUP} did not fire');
	POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old) or die;
	defined(POSIX::close($kqfd)) or die;
	defined(POSIX::close($$parent)) or die;
}

local $ENV{TEST_IOPOLLER} = 'PublicInbox::DSKQXS';
require './t/ds-poll.t';
