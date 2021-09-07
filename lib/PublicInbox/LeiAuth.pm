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
# call net_merge_all_done ->-> do per-WQ-class defined actions
package PublicInbox::LeiAuth;
use strict;
use v5.10.1;

sub do_auth_atfork { # used by IPC WQ workers
	my ($self, $wq) = @_;
	return if $wq->{-wq_worker_nr} != 0; # only first worker calls this
	my $lei = $wq->{lei};
	my $net = $lei->{net};
	if ($net->{-auth_done}) { # from previous worker... (ugly)
		$lei->{pkt_op_p}->pkt_do('net_merge_continue', $net) or
				$lei->fail("pkt_do net_merge_continue: $!");
		return;
	}
	eval { # fill auth info (may prompt user or read netrc)
		my $mics = $net->imap_common_init($lei);
		my $nn = $net->nntp_common_init($lei);
		# broadcast successful auth info to lei-daemon:
		$net->{-auth_done} = 1;
		$lei->{pkt_op_p}->pkt_do('net_merge_continue', $net) or
				die "pkt_do net_merge_continue: $!";
		$net->{mics_cached} = $mics if $mics;
		$net->{nn_cached} = $nn if $nn;
	};
	$lei->fail($@) if $@;
}

sub net_merge_all { # called in wq worker via wq_broadcast
	my ($wq, $net_new) = @_;
	my $net = $wq->{lei}->{net};
	%$net = (%$net, %$net_new);
}

# called by top-level lei-daemon when first worker is done with auth
# passes updated net auth info to current workers
sub net_merge_continue {
	my ($wq, $lei, $net_new) = @_;
	$wq->{-net_new} = $net_new; # for "lei up"
	$wq->wq_broadcast('PublicInbox::LeiAuth::net_merge_all', $net_new);
	$wq->net_merge_all_done($lei); # defined per-WQ
}

sub op_merge { # prepares PktOp->pair ops
	my ($self, $ops, $wq, $lei) = @_;
	$ops->{net_merge_continue} = [ \&net_merge_continue, $wq, $lei ];
}

sub new { bless \(my $x), __PACKAGE__ }

1;
