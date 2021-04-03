# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Authentication worker for anything that needs auth for read/write IMAP
# (eventually for read-only NNTP access)
package PublicInbox::LeiAuth;
use strict;
use v5.10.1;
use PublicInbox::PktOp qw(pkt_do);

sub do_auth_atfork { # used by IPC WQ workers
	my ($self, $wq) = @_;
	return if $wq->{-wq_worker_nr} != 0;
	my $lei = $wq->{lei};
	my $net = $lei->{net};
	eval {
		my $mics = $net->imap_common_init($lei);
		my $nn = $net->nntp_common_init($lei);
		pkt_do($lei->{pkt_op_p}, 'net_merge_continue', $net) or
				die "pkt_do net_merge_continue: $!";
		$net->{mics_cached} = $mics if $mics;
		$net->{nn_cached} = $nn if $nn;
	};
	$lei->fail($@) if $@;
}

sub net_merge_done1 { # bump merge-count in top-level lei-daemon
	my ($wq) = @_;
	return if ++$wq->{nr_net_merge_done} != $wq->{-wq_nr_workers};
	$wq->net_merge_complete; # defined per wq-class (e.g. LeiImport)
}

sub net_merge_all { # called in wq worker via wq_broadcast
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
	$ops->{net_merge_continue} = [ \&net_merge_continue, $wq ];
	$ops->{net_merge_done1} = [ \&net_merge_done1, $wq ];
}

sub new { bless \(my $x), __PACKAGE__ }

1;
