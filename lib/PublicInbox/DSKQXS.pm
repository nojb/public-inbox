# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
#
# kqueue support via IO::KQueue XS module.  This makes kqueue look
# like epoll to simplify the code in DS.pm.  This is NOT meant to be
# an all encompassing emulation of epoll via IO::KQueue, but just to
# support cases public-inbox-nntpd/httpd care about.
#
# It also implements signalfd(2) emulation via "tie".
package PublicInbox::DSKQXS;
use strict;
use warnings;
use parent qw(Exporter);
use Symbol qw(gensym);
use IO::KQueue;
use Errno qw(EAGAIN);
use PublicInbox::Syscall qw(EPOLLONESHOT EPOLLIN EPOLLOUT EPOLLET
	EPOLL_CTL_ADD EPOLL_CTL_MOD EPOLL_CTL_DEL);
our @EXPORT_OK = qw(epoll_ctl epoll_wait);

sub EV_DISPATCH () { 0x0080 }

# map EPOLL* bits to kqueue EV_* flags for EV_SET
sub kq_flag ($$) {
	my ($bit, $ev) = @_;
	if ($ev & $bit) {
		my $fl = EV_ENABLE;
		$fl |= EV_CLEAR if $fl & EPOLLET;

		# EV_DISPATCH matches EPOLLONESHOT semantics more closely
		# than EV_ONESHOT, in that EV_ADD is not required to
		# re-enable a disabled watch.
		($ev & EPOLLONESHOT) ? ($fl | EV_DISPATCH) : $fl;
	} else {
		EV_DISABLE;
	}
}

sub new {
	my ($class) = @_;
	bless { kq => IO::KQueue->new, owner_pid => $$ }, $class;
}

# returns a new instance which behaves like signalfd on Linux.
# It's wasteful in that it uses another FD, but it simplifies
# our epoll-oriented code.
sub signalfd {
	my ($class, $signo, $nonblock) = @_;
	my $sym = gensym;
	tie *$sym, $class, $signo, $nonblock; # calls TIEHANDLE
	$sym
}

sub TIEHANDLE { # similar to signalfd()
	my ($class, $signo, $nonblock) = @_;
	my $self = $class->new;
	$self->{timeout} = $nonblock ? 0 : -1;
	my $kq = $self->{kq};
	$kq->EV_SET($_, EVFILT_SIGNAL, EV_ADD) for @$signo;
	$self;
}

sub READ { # called by sysread() for signalfd compatibility
	my ($self, undef, $len, $off) = @_; # $_[1] = buf
	die "bad args for signalfd read" if ($len % 128) // defined($off);
	my $timeout = $self->{timeout};
	my $sigbuf = $self->{sigbuf} //= [];
	my $nr = $len / 128;
	my $r = 0;
	$_[1] = '';
	do {
		while ($nr--) {
			my $signo = shift(@$sigbuf) or last;
			# caller only cares about signalfd_siginfo.ssi_signo:
			$_[1] .= pack('L', $signo) . ("\0" x 124);
			$r += 128;
		}
		return $r if $r;
		my @events = eval { $self->{kq}->kevent($timeout) };
		# workaround https://rt.cpan.org/Ticket/Display.html?id=116615
		if ($@) {
			next if $@ =~ /Interrupted system call/;
			die;
		}
		if (!scalar(@events) && $timeout == 0) {
			$! = EAGAIN;
			return;
		}

		# Grab the kevent.ident (signal number).  The kevent.data
		# field shows coalesced signals, and maybe we'll use it
		# in the future...
		@$sigbuf = map { $_->[0] } @events;
	} while (1);
}

# for fileno() calls in PublicInbox::DS
sub FILENO { ${$_[0]->{kq}} }

sub epoll_ctl {
	my ($self, $op, $fd, $ev) = @_;
	my $kq = $self->{kq};
	if ($op == EPOLL_CTL_MOD) {
		$kq->EV_SET($fd, EVFILT_READ, kq_flag(EPOLLIN, $ev));
		eval { $kq->EV_SET($fd, EVFILT_WRITE, kq_flag(EPOLLOUT, $ev)) };
	} elsif ($op == EPOLL_CTL_DEL) {
		$kq->EV_SET($fd, EVFILT_READ, EV_DISABLE);
		eval { $kq->EV_SET($fd, EVFILT_WRITE, EV_DISABLE) };
	} else { # EPOLL_CTL_ADD
		$kq->EV_SET($fd, EVFILT_READ, EV_ADD|kq_flag(EPOLLIN, $ev));

		# we call this blindly for read-only FDs such as tied
		# DSKQXS (signalfd emulation) and Listeners
		eval {
			$kq->EV_SET($fd, EVFILT_WRITE, EV_ADD |
							kq_flag(EPOLLOUT, $ev));
		};
	}
	0;
}

sub epoll_wait {
	my ($self, $maxevents, $timeout_msec, $events) = @_;
	@$events = eval { $self->{kq}->kevent($timeout_msec) };
	if (my $err = $@) {
		# workaround https://rt.cpan.org/Ticket/Display.html?id=116615
		if ($err =~ /Interrupted system call/) {
			@$events = ();
		} else {
			die $err;
		}
	}
	# caller only cares for $events[$i]->[0]
	$_ = $_->[0] for @$events;
}

# kqueue is close-on-fork (not exec), so we must not close it
# in forked processes:
sub DESTROY {
	my ($self) = @_;
	my $kq = delete $self->{kq} or return;
	if (delete($self->{owner_pid}) == $$) {
		POSIX::close($$kq);
	}
}

1;
