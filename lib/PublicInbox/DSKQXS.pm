# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
#
# kqueue support via IO::KQueue XS module.  This makes kqueue look
# like epoll to simplify the code in DS.pm.  This is NOT meant to be
# an all encompassing emulation of epoll via IO::KQueue, but just to
# support cases public-inbox-nntpd/httpd care about.
# A pure-Perl version using syscall() is planned, and it should be
# faster due to the lack of syscall overhead.
package PublicInbox::DSKQXS;
use strict;
use warnings;
use parent qw(IO::KQueue);
use parent qw(Exporter);
use IO::KQueue;
use PublicInbox::Syscall qw(EPOLLONESHOT EPOLLIN EPOLLOUT EPOLLET
	EPOLL_CTL_DEL);
our @EXPORT_OK = qw(epoll_ctl epoll_wait);
my $owner_pid = -1; # kqueue is close-on-fork (yes, fork, not exec)

# map EPOLL* bits to kqueue EV_* flags for EV_SET
sub kq_flag ($$) {
	my ($bit, $ev) = @_;
	if ($ev & $bit) {
		my $fl = EV_ADD | EV_ENABLE;
		$fl |= EV_CLEAR if $fl & EPOLLET;
		($ev & EPOLLONESHOT) ? ($fl | EV_ONESHOT) : $fl;
	} else {
		EV_ADD | EV_DISABLE;
	}
}

sub new {
	my ($class) = @_;
	die 'non-singleton use not supported' if $owner_pid == $$;
	$owner_pid = $$;
	$class->SUPER::new;
}

sub epoll_ctl {
	my ($self, $op, $fd, $ev) = @_;
	if ($op != EPOLL_CTL_DEL) {
		$self->EV_SET($fd, EVFILT_READ, kq_flag(EPOLLIN, $ev));
		$self->EV_SET($fd, EVFILT_WRITE, kq_flag(EPOLLOUT, $ev));
	}
	0;
}

sub epoll_wait {
	my ($self, $maxevents, $timeout_msec, $events) = @_;
	@$events = eval { $self->kevent($timeout_msec) };
	if (my $err = $@) {
		# workaround https://rt.cpan.org/Ticket/Display.html?id=116615
		if ($err =~ /Interrupted system call/) {
			@$events = ();
		} else {
			die $err;
		}
	}
	# caller only cares for $events[$i]->[0]
	scalar(@$events);
}

sub DESTROY {
	my ($self) = @_;
	if ($owner_pid == $$) {
		POSIX::close($$self);
		$owner_pid = -1;
	}
}

1;
