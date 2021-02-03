# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for reading pipes and sockets off the DS event loop
package PublicInbox::InputPipe;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);

sub consume {
	my ($in, $cb, @args) = @_;
	my $self = bless { cb => $cb, sock => $in, args => \@args },__PACKAGE__;
	if ($PublicInbox::DS::in_loop) {
		eval { $self->SUPER::new($in, EPOLLIN|EPOLLET) };
		return $in->blocking(0) unless $@; # regular file sets $@
	}
	event_step($self) while $self->{sock};
}

sub event_step {
	my ($self) = @_;
	my ($r, $rbuf);
	while (($r = sysread($self->{sock}, $rbuf, 65536))) {
		$self->{cb}->(@{$self->{args} // []}, $rbuf);
	}
	if (defined($r)) { # EOF
		$self->{cb}->(@{$self->{args} // []}, '');
	} elsif ($!{EAGAIN}) {
		return;
	} else {
		$self->{cb}->(@{$self->{args} // []}, undef)
	}
	$self->{sock}->blocking ? delete($self->{sock}) : $self->close
}

1;
