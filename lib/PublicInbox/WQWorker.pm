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
	my ($cls, $wq, $sock) = @_;
	$sock->blocking(0);
	my $self = bless { sock => $sock, wq => $wq }, $cls;
	$self->SUPER::new($sock, EPOLLEXCLUSIVE|EPOLLIN|EPOLLET);
	$self;
}

sub event_step {
	my ($self) = @_;
	my $n;
	do {
		$n = $self->{wq}->recv_and_run($self->{sock});
	} while ($n);
	return if !defined($n) && $! == EAGAIN; # likely
	warn "wq worker error: $!\n" if !defined($n) && $! != ECONNRESET;
	$self->{wq}->wq_atexit_child if $self->{sock} == $self->{wq}->{-wq_s2};
	$self->close; # PublicInbox::DS::close
}

1;
