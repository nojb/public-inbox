# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# op dispatch socket, reads a message, runs a sub
# There may be multiple producers, but (for now) only one consumer
# Used for lei_xsearch and maybe other things
# "command" => [ $sub, @fixed_operands ]
package PublicInbox::PktOp;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS Exporter);
use Errno qw(EAGAIN EINTR);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
use Socket qw(AF_UNIX MSG_EOR SOCK_SEQPACKET);
use PublicInbox::IPC qw(ipc_freeze ipc_thaw);
our @EXPORT_OK = qw(pkt_do);

sub new {
	my ($cls, $r, $ops) = @_;
	my $self = bless { sock => $r, ops => $ops }, $cls;
	if ($PublicInbox::DS::in_loop) { # iff using DS->EventLoop
		$r->blocking(0);
		$self->SUPER::new($r, EPOLLIN|EPOLLET);
	}
	$self;
}

# returns a blessed object as the consumer, and a GLOB/IO for the producer
sub pair {
	my ($cls, $ops) = @_;
	my ($c, $p);
	socketpair($c, $p, AF_UNIX, SOCK_SEQPACKET, 0) or die "socketpair: $!";
	(new($cls, $c, $ops), $p);
}

sub pkt_do { # for the producer to trigger event_step in consumer
	my ($producer, $cmd, @args) = @_;
	send($producer, @args ? "$cmd\0".ipc_freeze(\@args) : $cmd, MSG_EOR);
}

sub close {
	my ($self) = @_;
	my $c = $self->{sock} or return;
	$c->blocking ? delete($self->{sock}) : $self->SUPER::close;
}

sub event_step {
	my ($self) = @_;
	my $c = $self->{sock};
	my $msg;
	while (1) {
		my $n = recv($c, $msg, 4096, 0);
		unless (defined $n) {
			return if $! == EAGAIN;
			next if $! == EINTR;
			$self->close;
			die "recv: $!";
		}
		my ($cmd, @pargs);
		if (index($msg, "\0") > 0) {
			($cmd, my $pargs) = split(/\0/, $msg, 2);
			@pargs = @{ipc_thaw($pargs)};
		} else {
			# for compatibility with the script/lei in client mode,
			# it doesn't load Sereal||Storable for startup speed
			($cmd, @pargs) = split(/ /, $msg);
		}
		my $op = $self->{ops}->{$cmd //= $msg};
		die "BUG: unknown message: `$cmd'" unless $op;
		my ($sub, @args) = @$op;
		$sub->(@args, @pargs);
		return $self->close if $msg eq ''; # close on EOF
	}
}

1;
