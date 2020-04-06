# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Sigfd;
use strict;
use parent qw(PublicInbox::DS);
use fields qw(sig); # hashref similar to %SIG, but signal numbers as keys
use PublicInbox::Syscall qw(signalfd EPOLLIN EPOLLET SFD_NONBLOCK);
use POSIX ();
use IO::Handle ();

# returns a coderef to unblock signals if neither signalfd or kqueue
# are available.
sub new {
	my ($class, $sig, $flags) = @_;
	my $self = fields::new($class);
	my %signo = map {;
		my $cb = $sig->{$_};
		# SIGWINCH is 28 on FreeBSD, NetBSD, OpenBSD
		my $num = ($_ eq 'WINCH' && $^O =~ /linux|bsd/i) ? 28 : do {
			my $m = "SIG$_";
			POSIX->$m;
		};
		$num => $cb;
	} keys %$sig;
	my $io;
	my $fd = signalfd(-1, [keys %signo], $flags);
	if (defined $fd && $fd >= 0) {
		$io = IO::Handle->new_from_fd($fd, 'r+');
	} elsif (eval { require PublicInbox::DSKQXS }) {
		$io = PublicInbox::DSKQXS->signalfd([keys %signo], $flags);
	} else {
		return; # wake up every second to check for signals
	}
	if ($flags & SFD_NONBLOCK) { # it can go into the event loop
		$self->SUPER::new($io, EPOLLIN | EPOLLET);
	} else { # master main loop
		$self->{sock} = $io;
	}
	$self->{sig} = \%signo;
	$self;
}

# PublicInbox::Daemon in master main loop (blocking)
sub wait_once ($) {
	my ($self) = @_;
	# 128 == sizeof(struct signalfd_siginfo)
	my $r = sysread($self->{sock}, my $buf, 128 * 64);
	if (defined($r)) {
		my $nr = $r / 128 - 1; # $nr may be -1
		for my $off (0..$nr) {
			# the first uint32_t of signalfd_siginfo: ssi_signo
			my $signo = unpack('L', substr($buf, 128 * $off, 4));
			my $cb = $self->{sig}->{$signo};
			$cb->($signo) if $cb ne 'IGNORE';
		}
	}
	$r;
}

# called by PublicInbox::DS in epoll_wait loop
sub event_step {
	while (wait_once($_[0])) {} # non-blocking
}

1;
