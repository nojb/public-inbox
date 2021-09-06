# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Authentication worker for anything that needs auth for read/write IMAP
# (eventually for read-only NNTP access)
#
# timelines
# lei-daemon              |  LeiAuth worker #0      | other WQ workers
# ----------------------------------------------------------
# spawns all workers ---->[ workers all start and run ipc_atfork_child ]
#                         | do_auth_atfork          | wq_worker_loop sleep
#                         | # reads .netrc          |
#                         | # queries git-credential|
#                         | send net_merge_continue |
#                         |         |               |
#                         |         v               |
# recv net_merge_continue <---------/               |
#            |            |                         |
#            v            |                         |
# broadcast net_merge_all [ all workers (including LeiAuth worker #0) ]
#                         [ LeiAuth worker #0 becomes just another WQ worker ]
#                         |
#                         | each worker sends net_merge_done1 to lei-daemon
#                         |              |  | ... |
#                         |              v  v     v
# recv net_merge_done1 <--<-------<------/--/--<--/
#
# call net_merge_all_done ->-> do per-class defined actions
package PublicInbox::LeiAuth;
use strict;
use v5.10.1;

sub do_auth_atfork { # used by IPC WQ workers
	my ($self, $wq) = @_;
	return if $wq->{-wq_worker_nr} != 0; # only first worker calls this
	my $lei = $wq->{lei};
	my $net = $lei->{net};
	eval { # fill auth info (may prompt user or read netrc)
		my $mics = $net->imap_common_init($lei);
		my $nn = $net->nntp_common_init($lei);
		# broadcast successful auth info to lei-daemon:
		$lei->{pkt_op_p}->pkt_do('net_merge_continue', $net) or
				die "pkt_do net_merge_continue: $!";
		$net->{mics_cached} = $mics if $mics;
		$net->{nn_cached} = $nn if $nn;
	};
	$lei->fail($@) if $@;
}

sub net_merge_done1 { # bump merge-count in top-level lei-daemon
	my ($wq) = @_;
	return if ++$wq->{nr_net_merge_done} != $wq->{-wq_nr_workers};
	$wq->net_merge_all_done; # defined per wq-class (e.g. LeiImport)
}

sub net_merge_all { # called in wq worker via wq_broadcast
	my ($wq, $net_new) = @_;
	my $net = $wq->{lei}->{net};
	%$net = (%$net, %$net_new);
	# notify daemon we're ready
	$wq->{lei}->{pkt_op_p}->pkt_do('net_merge_done1') or
		die "pkt_op_do net_merge_done1: $!";
}

# called by top-level lei-daemon when first worker is done with auth
sub net_merge_continue {
	my ($wq, $net_new) = @_;
	$wq->wq_broadcast('net_merge_all', $net_new); # pass to current workers
}

sub op_merge { # prepares PktOp->pair ops
	my ($self, $ops, $wq) = @_;
	$ops->{net_merge_continue} = [ \&net_merge_continue, $wq ];
	$ops->{net_merge_done1} = [ \&net_merge_done1, $wq ];
}

sub new { bless \(my $x), __PACKAGE__ }

1;
