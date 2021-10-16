# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for PublicInbox::IPC wq_* (work queue) workers
package PublicInbox::WQWorker;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLEXCLUSIVE);
use Errno qw(EAGAIN ECONNRESET);
use IO::Handle (); # blocking

sub new {
	my ($cls, $wq, $sock) = @_;
	$sock->blocking(0);
	my $self = bless { sock => $sock, wq => $wq }, $cls;
	$self->SUPER::new($sock, EPOLLEXCLUSIVE|EPOLLIN);
	$self;
}

sub event_step {
	my ($self) = @_;
	my $n = $self->{wq}->recv_and_run($self->{sock}) and return;
	unless (defined $n) {
		return if $! == EAGAIN;
		warn "recvmsg: $!" if $! != ECONNRESET;
	}
	$self->{sock} == $self->{wq}->{-wq_s2} and
		$self->{wq}->wq_atexit_child;
	$self->close; # PublicInbox::DS::close
}

1;
