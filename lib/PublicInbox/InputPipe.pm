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
	my $self = bless { cb => $cb, args => \@args }, __PACKAGE__;
	eval { $self->SUPER::new($in, EPOLLIN|EPOLLET) };
	return $self->requeue if $@; # regular file
	$in->blocking(0); # pipe or socket
}

sub event_step {
	my ($self) = @_;
	my $r = sysread($self->{sock}, my $rbuf, 65536);
	if ($r) {
		$self->{cb}->(@{$self->{args} // []}, $rbuf);
		return $self->requeue; # may be regular file or pipe
	}
	if (defined($r)) { # EOF
		$self->{cb}->(@{$self->{args} // []}, '');
	} elsif ($!{EAGAIN}) {
		return;
	} else { # another error
		$self->{cb}->(@{$self->{args} // []}, undef)
	}
	$self->{sock}->blocking ? delete($self->{sock}) : $self->close
}

1;
