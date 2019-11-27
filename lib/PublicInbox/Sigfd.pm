# Copyright (C) 2019 all contributors <meta@public-inbox.org>
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
	my $r = sysread($self->{sock}, my $buf, 128 * 64);
	if (defined($r)) {
		while (1) {
			my $sig = unpack('L', $buf);
			my $cb = $self->{sig}->{$sig};
			$cb->($sig) if $cb ne 'IGNORE';
			return $r if length($buf) == 128;
			$buf = substr($buf, 128);
		}
	}
	$r;
}

# called by PublicInbox::DS in epoll_wait loop
sub event_step {
	while (wait_once($_[0])) {} # non-blocking
}

1;
