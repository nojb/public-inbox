# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
#
# poll(2) via IO::Poll core module.  This makes poll look
# like epoll to simplify the code in DS.pm.  This is NOT meant to be
# an all encompassing emulation of epoll via IO::Poll, but just to
# support cases public-inbox-nntpd/httpd care about.
package PublicInbox::DSPoll;
use strict;
use warnings;
use parent qw(Exporter);
use IO::Poll;
use PublicInbox::Syscall qw(EPOLLONESHOT EPOLLIN EPOLLOUT EPOLL_CTL_DEL);
our @EXPORT = qw(epoll_ctl epoll_wait);

sub new { bless {}, $_[0] } # fd => events

sub epoll_ctl {
	my ($self, $op, $fd, $ev) = @_;

	# not wasting time on error checking
	if ($op != EPOLL_CTL_DEL) {
		$self->{$fd} = $ev;
	} else {
		delete $self->{$fd};
	}
	0;
}

sub epoll_wait {
	my ($self, $maxevents, $timeout_msec, $events) = @_;
	my @pset;
	while (my ($fd, $events) = each %$self) {
		my $pevents = $events & EPOLLIN ? POLLIN : 0;
		$pevents |= $events & EPOLLOUT ? POLLOUT : 0;
		push(@pset, $fd, $pevents);
	}
	@$events = ();
	my $n = IO::Poll::_poll($timeout_msec, @pset);
	if ($n >= 0) {
		for (my $i = 0; $i < @pset; ) {
			my $fd = $pset[$i++];
			my $revents = $pset[$i++] or next;
			delete($self->{$fd}) if $self->{$fd} & EPOLLONESHOT;
			push @$events, [ $fd ];
		}
		my $nevents = scalar @$events;
		if ($n != $nevents) {
			warn "BUG? poll() returned $n, but got $nevents";
		}
	}
	$n;
}

1;
