# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# bytecode dispatch pipe, reads a byte, runs a sub
# byte => [ sub, @operands ]
package PublicInbox::OpPipe;
use strict;
use v5.10.1;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN);

sub new {
	my ($cls, $rd, $op_map, $in_loop) = @_;
	my $self = bless { sock => $rd, op_map => $op_map }, $cls;
	# 1031: F_SETPIPE_SZ, 4096: page size
	fcntl($rd, 1031, 4096) if $^O eq 'linux';
	if ($in_loop) { # iff using DS->EventLoop
		$rd->blocking(0);
		$self->SUPER::new($rd, EPOLLIN);
	}
	$self;
}

sub event_step {
	my ($self) = @_;
	my $rd = $self->{sock};
	my $byte;
	until (defined(sysread($rd, $byte, 1))) {
		return if $!{EAGAIN};
		next if $!{EINTR};
		die "read \$rd: $!";
	}
	my $op = $self->{op_map}->{$byte} or die "BUG: unknown byte `$byte'";
	if ($byte eq '') { # close on EOF
		$rd->blocking ? delete($self->{sock}) : $self->close;
	}
	my ($sub, @args) = @$op;
	$sub->(@args);
}

1;
