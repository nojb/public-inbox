# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::EOFpipe;
use strict;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);

sub new {
	my (undef, $rd, $cb, $arg) = @_;
	my $self = bless {  cb => $cb, arg => $arg }, __PACKAGE__;
	# 1031: F_SETPIPE_SZ, 4096: page size
	fcntl($rd, 1031, 4096) if $^O eq 'linux';
	$self->SUPER::new($rd, EPOLLIN|EPOLLONESHOT);
}

sub event_step {
	my ($self) = @_;
	if ($self->do_read(my $buf, 1) == 0) { # auto-closed
		$self->{cb}->($self->{arg});
	}
}

1;
