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
	$mset_opt->{limit} = $lei->{opt}->{limit} // 10000;
	my $q = $mset_opt->{q_raw} = $lss->{-cfg}->{'lei.q'} //
				return $lei->fail("lei.q unset in $f");
	my $lse = $lei->{lse} // die 'BUG: {lse} missing';
	if (ref($q)) {
		$mset_opt->{qstr} = $lse->query_argv_to_string($lse->git, $q);
	} else {
		$lse->query_approxidate($lse->git, $mset_opt->{qstr} = $q);
	}
	my $o = $lei->{opt}->{output} = $lss->{-cfg}->{'lei.q.output'} //
		return $lei->fail("lei.q.output unset in $f");
	ref($o) and return $lei->fail("multiple values of lei.q.output in $f");
	if (defined(my $dd = $lss->{-cfg}->{'lei.q.dedupe'})) {
		$lss->translate_dedupe($lei, $dd) or return;
		$lei->{opt}->{dedupe} = $dd;
	}
	for my $k (qw(only include exclude)) {
		my $v = $lss->{-cfg}->get_all("lei.q.$k") // next;
		$lei->{opt}->{$k} = $v;
	}
	for my $k (qw(external local remote
			import-remote import-before threads)) {
		my $c = "lei.q.$k";
		my $v = $lss->{-cfg}->{$c} // next;
		ref($v) and return $lei->fail("multiple values of $c in $f");
		$lei->{opt}->{$k} = $v;
	}
	$lei->{lss} = $lss; # for LeiOverview->new and query_remote_mboxrd
	my $lxs = $lei->lxs_prepare or return;
	$lei->ale->refresh_externals($lxs, $lei);
	$lei->_start_query;
}

sub up1_redispatch {
	my ($lei, $out, $op_p) = @_;
	my $l;
	if (defined($lei->{opt}->{mua})) { # single output
		$l = $lei;
	} else { # multiple outputs
		$l = bless { %$lei }, ref($lei);
		$l->{opt} = { %{$l->{opt}} }; # deep copy
		delete $l->{opt}->{all};
		delete $l->{sock}; # do not close
		# make close($l->{1}) happy in lei->dclose
		open my $fh, '>&', $l->{1} or
			return $l->child_error(0, "dup: $!");
		$l->{1} = $fh;
		$l->qerr("# updating $out");
	}
	$l->{''} = $op_p; # daemon only ($l => $lei => script/lei)
	eval { $l->dispatch('up', $out) };
	$lei->child_error(0, $@) if $@ || $l->{failed}; # lei->fail()
}

sub redispatch_all ($$) {
	my ($self, $lei) = @_;
	# re-dispatch into our event loop w/o creating an extra fork-level
	$lei->{fmsg} = PublicInbox::LeiFinmsg->new($lei);
	my ($op_c, $op_p) = PublicInbox::PktOp->pair;
	for my $o (@{$self->{local} // []}, @{$self->{remote} // []}) {
		PublicInbox::DS::requeue(sub {
			up1_redispatch($lei, $o, $op_p);
		});
	}
	$lei->event_step_init;
	$lei->pkt_ops($op_c->{ops} = { '' => [$lei->can('dclose'), $lei] });
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
	} elsif ($lei->{lse}) {
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
	redispatch_all($self, $lei);
}

sub _complete_up {
	my ($lei, @argv) = @_;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	map { $match_cb->($_) } PublicInbox::LeiSavedSearch::list($lei);
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;

1;
