# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei up" - updates the result of "lei q --save"
package PublicInbox::LeiUp;
use strict;
use v5.10.1;
# n.b. we use LeiInput to setup IMAP auth
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::LeiSavedSearch; # OverIdx
use PublicInbox::DS;
use PublicInbox::PktOp;
use PublicInbox::LeiFinmsg;
my $REMOTE_RE = qr!\A(?:imap|http)s?://!i; # http(s) will be for JMAP

sub up1 ($$) {
	my ($lei, $out) = @_;
	# precedence note for CLI switches between lei q and up:
	# `lei q --only' > `lei q --no-(remote|local|external)'
	# `lei up --no-(remote|local|external)' > `lei.q.only' in saved search
	my %no = map {
		my $v = $lei->{opt}->{$_}; # set by CLI
		(defined($v) && !$v) ? ($_ => 1) : ();
	} qw(remote local external);
	my $cli_exclude = delete $lei->{opt}->{exclude};
	my $lss = PublicInbox::LeiSavedSearch->up($lei, $out) or return;
	my $f = $lss->{'-f'};
	my $mset_opt = $lei->{mset_opt} = { relevance => -2 };
	my $q = $lss->{-cfg}->get_all('lei.q') //
				die("lei.q unset in $f (out=$out)\n");
	my $lse = $lei->{lse} // die 'BUG: {lse} missing';
	my $rawstr = $lss->{-cfg}->{'lei.internal.rawstr'} //
		(scalar(@$q) == 1 && substr($q->[0], -1) eq "\n");
	if ($rawstr) {
		scalar(@$q) > 1 and
			die "$f: lei.q has multiple values (@$q) (out=$out)\n";
		$lse->query_approxidate($lse->git, $mset_opt->{qstr} = $q->[0]);
	} else {
		$mset_opt->{qstr} = $lse->query_argv_to_string($lse->git, $q);
	}
	# n.b. only a few CLI args are accepted for "up", so //= usually sets
	for my $k ($lss->ARRAY_FIELDS) {
		my $v = $lss->{-cfg}->get_all("lei.q.$k") // next;
		$lei->{opt}->{$k} //= $v;
	}

	# --no-(local|remote) CLI flags overrided saved `lei.q.only'
	my $only = $lei->{opt}->{only};
	@$only = map { $lei->get_externals($_) } @$only if $only;
	if (scalar keys %no && $only) {
		@$only = grep(!m!\Ahttps?://!i, @$only) if $no{remote};
		@$only = grep(m!\Ahttps?://!i, @$only) if $no{'local'};
	}
	if ($cli_exclude) {
		my $ex = $lei->canonicalize_excludes($cli_exclude);
		@$only = grep { !$ex->{$_} } @$only if $only;
		push @{$lei->{opt}->{exclude}}, @$cli_exclude;
	}
	delete $lei->{opt}->{only} if $no{external} || ($only && !@$only);
	for my $k ($lss->BOOL_FIELDS, $lss->SINGLE_FIELDS) {
		my $v = $lss->{-cfg}->get_1("lei.q.$k") // next;
		$lei->{opt}->{$k} //= $v;
	}
	my $o = $lei->{opt}->{output} // '';
	return die("lei.q.output unset in $f (out=$out)\n") if $o eq '';
	$lss->translate_dedupe($lei) or return;
	$lei->{lss} = $lss; # for LeiOverview->new and query_remote_mboxrd
	my $lxs = $lei->lxs_prepare or return;
	$lei->ale->refresh_externals($lxs, $lei);
	$lei->_start_query;
}

sub redispatch_all ($$) {
	my ($self, $lei) = @_;
	my $upq = [ (@{$self->{o_local} // []}, @{$self->{o_remote} // []}) ];
	return up1($lei, $upq->[0]) if @$upq == 1; # just one, may start MUA

	PublicInbox::OverIdx::fork_ok($lei->{opt});
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
	$lei->{daemon_pid} = $$;
	$lei->event_step_init; # wait for client disconnects
	for my $out (@first_batch) {
		PublicInbox::DS::requeue(
			PublicInbox::LeiUp1::nxt($lei, $out, $op_p));
	}
}

sub filter_lss {
	my ($self, $lei, $all) = @_;
	my @outs = PublicInbox::LeiSavedSearch::list($lei);
	if ($all eq 'local') {
		$self->{o_local} = [ grep(!/$REMOTE_RE/, @outs) ];
	} elsif ($all eq 'remote') {
		$self->{o_remote} = [ grep(/$REMOTE_RE/, @outs) ];
	} elsif ($all eq '') {
		$self->{o_remote} = [ grep(/$REMOTE_RE/, @outs) ];
		$self->{o_local} = [ grep(!/$REMOTE_RE/, @outs) ];
	} else {
		undef;
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
		filter_lss($self, $lei, $all) // return
			$lei->fail("only --all=$all not understood");
	} elsif ($lei->{lse}) { # redispatched
		scalar(@outs) == 1 or die "BUG: lse set w/ >1 out[@outs]";
		return up1($lei, $outs[0]);
	} else {
		$self->{o_remote} = [ grep(/$REMOTE_RE/, @outs) ];
		$self->{o_local} = [ grep(!/$REMOTE_RE/, @outs) ];
	}
	$lei->{lse} = $lei->_lei_store(1)->write_prepare($lei)->search;
	((@{$self->{o_local} // []} + @{$self->{o_remote} // []}) > 1 &&
		defined($opt->{mua})) and return $lei->fail(<<EOM);
multiple outputs and --mua= are incompatible
EOM
	if ($self->{o_remote}) { # setup lei->{auth}
		$self->prepare_inputs($lei, $self->{o_remote}) or return;
	}
	if ($lei->{auth}) { # start auth worker
		require PublicInbox::NetWriter;
		bless $lei->{net}, 'PublicInbox::NetWriter';
		$lei->wq1_start($self);
		# net_merge_all_done will fire when auth is done
	} else {
		redispatch_all($self, $lei); # see below
	}
}

# called in top-level lei-daemon when LeiAuth is done
sub net_merge_all_done {
	my ($self, $lei) = @_;
	$lei->{net} = delete($self->{-net_new}) if $self->{-net_new};
	$self->wq_close;
	eval { redispatch_all($self, $lei) };
	$lei->child_error(0, "E: $@") if $@;
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
	my $o = " (output: $self->{out})"; # add to all warnings
	my $cb = $SIG{__WARN__} // \&CORE::warn;
	local $SIG{__WARN__} = sub {
		my @m = @_;
		push(@m, $o) if !@m || $m[-1] !~ s/\n\z/$o\n/;
		$cb->(@m);
	};
	$l->{-up1} = $self; # for LeiUp1->DESTROY
	delete @$l{qw(-socks -event_init_done)};
	my ($op_c, $op_p) = PublicInbox::PktOp->pair;
	$self->{unref_on_destroy} = $op_c->{sock}; # to cleanup $lei->{-socks}
	$lei->pkt_ops($op_c->{ops} //= {}); # errors from $l -> script/lei
	push @{$lei->{-socks}}, $op_c->{sock}; # script/lei signals to $l
	$l->{sock} = $op_p->{op_p}; # receive signals from op_c->{sock}
	$op_c = $op_p = undef;

	eval { $l->dispatch('up', $self->{out}) };
	$lei->child_error(0, $@) if $@ || $l->{failed}; # lei->fail()
}

sub DESTROY {
	my ($self) = @_;
	my $lei = $self->{lei}; # the original, from lei_up
	return if $lei->{daemon_pid} != $$;
	my $sock = delete $self->{unref_on_destroy};
	my $s = $lei->{-socks} // [];
	@$s = grep { $_ != $sock } @$s;
	my $out = shift(@{$lei->{-upq}}) or return;
	PublicInbox::DS::requeue(nxt($lei, $out, $self->{op_p}));
}

1;
