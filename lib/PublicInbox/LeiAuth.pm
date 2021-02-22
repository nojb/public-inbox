# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Authentication worker for anything that needs auth for read/write IMAP
# (eventually for read-only NNTP access)
package PublicInbox::LeiAuth;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::PktOp qw(pkt_do);

sub net_merge {
	my ($lei, $net_new) = @_;
	if ($lei->{pkt_op_p}) { # from lei_convert worker
		pkt_do($lei->{pkt_op_p}, 'net_merge', $net_new);
	} else { # single lei-daemon consumer
		my $self = $lei->{auth} or return; # client disconnected
		my $net = $self->{net};
		%$net = (%$net, %$net_new);
	}
}

sub do_auth { # called via wq_io_do
	my ($self) = @_;
	my ($lei, $net) = @$self{qw(lei net)};
	$net->imap_common_init($lei);
	net_merge($lei, $net); # tell lei-daemon updated auth info
}

sub do_auth_atfork { # used by IPC WQ workers
	my ($self, $wq) = @_;
	return if $wq->{-wq_worker_nr} != 0;
	my $lei = $wq->{lei};
	my $net = $self->{net};
	my $mics = $net->imap_common_init($lei);
	net_merge($lei, $net);
	$net->{mics_cached} = $mics;
}

sub net_merge_done1 { # bump merge-count in top-level lei-daemon
	my ($wq) = @_;
	return if ++$wq->{nr_net_merge_done} != $wq->{-wq_nr_workers};
	$wq->net_merge_complete; # defined per wq-class (e.g. LeiImport)
}

sub net_merge_all { # called via wq_broadcast
	my ($wq, $net_new) = @_;
	my $net = $wq->{lei}->{net};
	%$net = (%$net, %$net_new);
	pkt_do($wq->{lei}->{pkt_op_p}, 'net_merge_done1') or
		die "pkt_op_do net_merge_done1: $!";
}

# called by top-level lei-daemon when first worker is done with auth
sub net_merge_continue {
	my ($wq, $net_new) = @_;
	$wq->wq_broadcast('net_merge_all', $net_new);
}

sub op_merge { # prepares PktOp->pair ops
	my ($self, $ops, $wq) = @_;
	$ops->{net_merge} = [ \&net_merge_continue, $wq ];
	$ops->{net_merge_done1} = [ \&net_merge_done1, $wq ];
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
	my $op = $lei->workers_start($self, 'auth', 1, {
		'net_merge' => [ \&net_merge, $lei ],
		'' => [ \&auth_eof, $lei, $post_auth_cb, @args ],
	});
	$self->wq_io_do('do_auth', []);
	$self->wq_close(1);
	while ($op && $op->{sock}) { $op->event_step }
}

sub ipc_atfork_child {
	my ($self) = @_;
	delete $self->{lei}->{auth}; # drop circular ref
	$self->{lei}->lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
}

sub new {
	my ($cls, $net) = @_; # net may be NetReader or descendant (NetWriter)
	bless { net => $net }, $cls;
}

1;
