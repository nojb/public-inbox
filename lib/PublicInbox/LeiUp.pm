# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei up" - updates the result of "lei q --save"
package PublicInbox::LeiUp;
use strict;
use v5.10.1;
# n.b. we use LeiInput to setup IMAP auth
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::LeiSavedSearch;
use PublicInbox::DS;
use PublicInbox::PktOp;
use PublicInbox::LeiFinmsg;
my $REMOTE_RE = qr!\A(?:imap|http)s?://!i; # http(s) will be for JMAP

sub up1 ($$) {
	my ($lei, $out) = @_;
	my $lss = PublicInbox::LeiSavedSearch->up($lei, $out) or return;
	my $f = $lss->{'-f'};
	my $mset_opt = $lei->{mset_opt} = { relevance => -2 };
	my $q = $mset_opt->{q_raw} = $lss->{-cfg}->{'lei.q'} //
				return $lei->fail("lei.q unset in $f");
	my $lse = $lei->{lse} // die 'BUG: {lse} missing';
	if (ref($q)) {
		$mset_opt->{qstr} = $lse->query_argv_to_string($lse->git, $q);
	} else {
		$lse->query_approxidate($lse->git, $mset_opt->{qstr} = $q);
	}
	# n.b. only a few CLI args are accepted for "up", so //= usually sets
	for my $k ($lss->ARRAY_FIELDS) {
		my $v = $lss->{-cfg}->get_all("lei.q.$k") // next;
		$lei->{opt}->{$k} //= $v;
	}
	for my $k ($lss->BOOL_FIELDS, $lss->SINGLE_FIELDS) {
		my $v = $lss->{-cfg}->get_1("lei.q.$k") // next;
		$lei->{opt}->{$k} //= $v;
	}
	my $o = $lei->{opt}->{output} // '';
	return $lei->fail("lei.q.output unset in $f (out=$out)") if $o eq '';
	$lss->translate_dedupe($lei) or return;
	$lei->{lss} = $lss; # for LeiOverview->new and query_remote_mboxrd
	my $lxs = $lei->lxs_prepare or return;
	$lei->ale->refresh_externals($lxs, $lei);
	$lei->_start_query;
}

sub redispatch_all ($$) {
	my ($self, $lei) = @_;
	my $upq = [ (@{$self->{local} // []}, @{$self->{remote} // []}) ];
	return up1($lei, $upq->[0]) if @$upq == 1; # just one, may start MUA

	# FIXME: this is also used per-query, see lei->_start_query
	my $j = $lei->{opt}->{jobs} || do {
		my $n = $self->detect_nproc // 1;
		$n > 4 ? 4 : $n;
	};
	$j = ($j =~ /\A([0-9]+)/) ? $1 + 0 : 1; # may be --jobs=$x,$m on CLI
	# re-dispatch into our event loop w/o creating an extra fork-level
	# $upq will be drained via DESTROY as each query finishes
	$lei->{fmsg} = PublicInbox::LeiFinmsg->new($lei);
	my ($op_c, $op_p) = PublicInbox::PktOp->pair;
	# call lei->dclose when upq is done processing:
	$op_c->{ops} = { '' => [ $lei->can('dclose'), $lei ] };
	my @first_batch = splice(@$upq, 0, $j); # initial parallelism
	$lei->{-upq} = $upq;
	$lei->event_step_init; # wait for client disconnects
	for my $out (@first_batch) {
		PublicInbox::DS::requeue(
			PublicInbox::LeiUp1::nxt($lei, $out, $op_p));
	}
}

sub lei_up {
	my ($lei, @outs) = @_;
	my $opt = $lei->{opt};
	my $self = bless { -mail_sync => 1 }, __PACKAGE__;
	if (defined(my $all = $opt->{all})) {
		return $lei->fail("--all and @outs incompatible") if @outs;
		defined($opt->{mua}) and return
			$lei->fail('--all and --mua= are incompatible');
		@outs = PublicInbox::LeiSavedSearch::list($lei);
		if ($all eq 'local') {
			$self->{local} = [ grep(!/$REMOTE_RE/, @outs) ];
		} elsif ($all eq 'remote') {
			$self->{remote} = [ grep(/$REMOTE_RE/, @outs) ];
		} elsif ($all eq '') {
			$self->{remote} = [ grep(/$REMOTE_RE/, @outs) ];
			$self->{local} = [ grep(!/$REMOTE_RE/, @outs) ];
		} else {
			$lei->fail("only --all=$all not understood");
		}
	} elsif ($lei->{lse}) { # redispatched
		scalar(@outs) == 1 or die "BUG: lse set w/ >1 out[@outs]";
		return up1($lei, $outs[0]);
	} else {
		$self->{remote} = [ grep(/$REMOTE_RE/, @outs) ];
		$self->{local} = [ grep(!/$REMOTE_RE/, @outs) ];
	}
	$lei->{lse} = $lei->_lei_store(1)->write_prepare($lei)->search;
	((@{$self->{local} // []} + @{$self->{remote} // []}) > 1 &&
		defined($opt->{mua})) and return $lei->fail(<<EOM);
multiple outputs and --mua= are incompatible
EOM
	if ($self->{remote}) { # setup lei->{auth}
		$self->prepare_inputs($lei, $self->{remote}) or return;
	}
	if ($lei->{auth}) { # start auth worker
		require PublicInbox::NetWriter;
		bless $lei->{net}, 'PublicInbox::NetWriter';
		$lei->{auth}->op_merge(my $ops = {}, $self, $lei);
		(my $op_c, $ops) = $lei->workers_start($self, 1, $ops);
		$lei->{wq1} = $self;
		$lei->wait_wq_events($op_c, $ops);
		# net_merge_all_done will fire when auth is done
	} else {
		redispatch_all($self, $lei); # see below
	}
}

# called in top-level lei-daemon when LeiAuth is done
sub net_merge_all_done {
	my ($self, $lei) = @_;
	$lei->{net} = delete($self->{-net_new}) if $self->{-net_new};
	$self->wq_close(1);
	eval { redispatch_all($self, $lei) };
	warn "E: $@" if $@;
}

sub _complete_up { # lei__complete hook
	my ($lei, @argv) = @_;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	map { $match_cb->($_) } PublicInbox::LeiSavedSearch::list($lei);
}

sub _wq_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($wq, $lei) = @$arg;
	$lei->child_error($?, 'auth failure') if $?
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;

package PublicInbox::LeiUp1; # for redispatch_all
use strict;
use v5.10.1;

sub nxt ($$$) {
	my ($lei, $out, $op_p) = @_;
	bless { lei => $lei, out => $out, op_p => $op_p }, __PACKAGE__;
}

sub event_step { # runs via PublicInbox::DS::requeue
	my ($self) = @_;
	my $lei = $self->{lei}; # the original, from lei_up
	my $l = bless { %$lei }, ref($lei); # per-output copy
	delete($l->{sock}) or return; # client disconnected if {sock} is gone
	$l->{opt} = { %{$l->{opt}} }; # deep copy
	delete $l->{opt}->{all};
	$l->qerr("# updating $self->{out}");
	$l->{up_op_p} = $self->{op_p}; # ($l => $lei => script/lei)
	my $cb = $SIG{__WARN__} // \&CORE::warn;
	my $o = " (output: $self->{out})";
	local $SIG{__WARN__} = sub {
		my @m = @_;
		push(@m, $o) if !@m || $m[-1] !~ s/\n\z/$o\n/;
		$cb->(@m);
	};
	eval { $l->dispatch('up', $self->{out}) };
	$lei->child_error(0, $@) if $@ || $l->{failed}; # lei->fail()

	# onto the next:
	my $out = shift(@{$lei->{-upq}}) or return;
	PublicInbox::DS::requeue(nxt($lei, $out, $self->{op_p}));
}

1;
