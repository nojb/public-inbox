# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for PublicInbox::IPC wq_* (work queue) workers
package PublicInbox::WQWorker;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLEXCLUSIVE EPOLLET);
use Errno qw(EAGAIN ECONNRESET);
use IO::Handle (); # blocking

sub new {
	my (undef, $wq) = @_;
	my $s2 = $wq->{-wq_s2} // die 'BUG: no -wq_s2';
	$s2->blocking(0);
	my $self = bless { sock => $s2, wq => $wq }, __PACKAGE__;
	$self->SUPER::new($s2, EPOLLEXCLUSIVE|EPOLLIN|EPOLLET);
	$self;
}

sub event_step {
	my ($self) = @_;
	my $n;
	do {
		$n = $self->{wq}->recv_and_run($self->{sock}, 4096 * 33);
	} while ($n);
	return if !defined($n) && $! == EAGAIN; # likely
	warn "wq worker error: $!\n" if !defined($n) && $! != ECONNRESET;
	$self->{wq}->wq_atexit_child;
	$self->close; # PublicInbox::DS::close
}

1;