# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Authentication worker for anything that needs auth for read/write IMAP
# (eventually for read-only NNTP access)
package PublicInbox::LeiAuth;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::PktOp qw(pkt_do);
use PublicInbox::NetReader;

sub nrd_merge {
	my ($lei, $nrd_new) = @_;
	if ($lei->{pkt_op_p}) { # from lei_convert worker
		pkt_do($lei->{pkt_op_p}, 'nrd_merge', $nrd_new);
	} else { # single lei-daemon consumer
		my $self = $lei->{auth} or return; # client disconnected
		my $nrd = $self->{nrd};
		%$nrd = (%$nrd, %$nrd_new);
	}
}

sub do_auth { # called via wq_io_do
	my ($self) = @_;
	my ($lei, $nrd) = @$self{qw(lei nrd)};
	$nrd->imap_common_init($lei);
	nrd_merge($lei, $nrd); # tell lei-daemon updated auth info
}

sub do_finish_auth { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($self, $lei, $post_auth_cb, @args) = @$arg;
	$? ? $lei->dclose : $post_auth_cb->(@args);
}

sub auth_eof {
	my ($lei, $post_auth_cb, @args) = @_;
	my $self = delete $lei->{auth} or return;
	$self->wq_wait_old(\&do_finish_auth, $lei, $post_auth_cb, @args);
}

sub auth_start {
	my ($self, $lei, $post_auth_cb, @args) = @_;
	$lei->_lei_cfg(1); # workers may need to read config
	my $op = $lei->workers_start($self, 'auth', 1, {
		'nrd_merge' => [ \&nrd_merge, $lei ],
		'' => [ \&auth_eof, $lei, $post_auth_cb, @args ],
	});
	$self->wq_io_do('do_auth', []);
	$self->wq_close(1);
	while ($op && $op->{sock}) { $op->event_step }
}

sub ipc_atfork_child {
	my ($self) = @_;
	# prevent {sock} from being closed in lei_atfork_child:
	my $s = delete $self->{lei}->{sock};
	delete $self->{lei}->{auth}; # drop circular ref
	$self->{lei}->lei_atfork_child;
	$self->{lei}->{sock} = $s if $s;
	$self->SUPER::ipc_atfork_child;
}

sub new {
	my ($cls, $nrd) = @_;
	bless { nrd => $nrd }, $cls;
}

1;
