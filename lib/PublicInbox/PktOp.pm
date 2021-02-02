# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# op dispatch socket, reads a message, runs a sub
# There may be multiple producers, but (for now) only one consumer
# Used for lei_xsearch and maybe other things
# "literal" => [ sub, @operands ]
# /regexp/ => [ sub, @operands ]
package PublicInbox::PktOp;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use Errno qw(EAGAIN EINTR);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
use Socket qw(AF_UNIX MSG_EOR SOCK_SEQPACKET);

sub new {
	my ($cls, $r, $ops, $in_loop) = @_;
	my $self = bless { sock => $r, ops => $ops, re => [] }, $cls;
	if (ref($ops) eq 'ARRAY') {
		my %ops;
		for my $op (@$ops) {
			if (ref($op->[0])) {
				push @{$self->{re}}, $op;
			} else {
				$ops{$op->[0]} = $op->[1];
			}
		}
		$self->{ops} = \%ops;
	}
	if ($in_loop) { # iff using DS->EventLoop
		$r->blocking(0);
		$self->SUPER::new($r, EPOLLIN|EPOLLET);
	}
	$self;
}

# returns a blessed object as the consumer, and a GLOB/IO for the producer
sub pair {
	my ($cls, $ops, $in_loop) = @_;
	my ($c, $p);
	socketpair($c, $p, AF_UNIX, SOCK_SEQPACKET, 0) or die "socketpair: $!";
	(new($cls, $c, $ops, $in_loop), $p);
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
	do {
		my $n = recv($c, $msg, 128, 0);
		unless (defined $n) {
			return if $! == EAGAIN;
			next if $! == EINTR;
			$self->close;
			die "recv: $!";
		}
		my $op = $self->{ops}->{$msg};
		unless ($op) {
			for my $re_op (@{$self->{re}}) {
				$msg =~ $re_op->[0] or next;
				$op = $re_op->[1];
				last;
			}
		}
		die "BUG: unknown message: `$msg'" unless $op;
		my ($sub, @args) = @$op;
		$sub->(@args);
		return $self->close if $msg eq ''; # close on EOF
	} while (1);
}

1;
