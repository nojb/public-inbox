# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei up" - updates the result of "lei q --save"
package PublicInbox::LeiUp;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use parent qw(PublicInbox::IPC);

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
	$lei->{lss} = $lss; # for LeiOverview->new
	my $lxs = $lei->lxs_prepare or return;
	$lei->ale->refresh_externals($lxs, $lei);
	$lei->_start_query;
}

sub up1_redispatch {
	my ($lei, $out, $op_p) = @_;
	my $l = bless { %$lei }, ref($lei);
	$l->{opt} = { %{$l->{opt}} };
	delete $l->{sock};
	$l->{''} = $op_p; # daemon only
	eval {
		$l->qerr("# updating $out");
		up1($l, $out);
		$l->qerr("# $out done");
	};
	$l->child_error(1 << 8, $@) if $@;
}

sub lei_up {
	my ($lei, @outs) = @_;
	$lei->{lse} = $lei->_lei_store(1)->search;
	my $opt = $lei->{opt};
	my @local;
	if (defined $opt->{all}) {
		return $lei->fail("--all and @outs incompatible") if @outs;
		length($opt->{mua}//'') and return
			$lei->fail('--all and --mua= are incompatible');

		# supporting IMAP outputs is more involved due to
		# git-credential prompts.  TODO: add this in 1.8
		$opt->{all} eq 'local' or return
			$lei->fail('only --all=local works at the moment');
		my @all = PublicInbox::LeiSavedSearch::list($lei);
		@local = grep(!m!\Aimaps?://!i, @all);
	} else {
		@local = @outs;
	}
	if (scalar(@outs) > 1) {
		length($opt->{mua}//'') and return $lei->fail(<<EOM);
multiple outputs and --mua= are incompatible
EOM
		# TODO:
		return $lei->fail(<<EOM) if grep(m!\Aimaps?://!i, @outs);
multiple destinations only supported for local outputs (FIXME)
EOM
	}
	if (scalar(@local) > 1) {
		$lei->_lei_store->write_prepare($lei); # share early
		# daemon mode, re-dispatch into our event loop w/o
		# creating an extra fork-level
		require PublicInbox::DS;
		require PublicInbox::PktOp;
		my ($op_c, $op_p) = PublicInbox::PktOp->pair;
		for my $o (@local) {
			PublicInbox::DS::requeue(sub {
				up1_redispatch($lei, $o, $op_p);
			});
		}
		$lei->event_step_init;
		$op_c->{ops} = { '' => [$lei->can('dclose'), $lei] };
	} else {
		up1($lei, $local[0]);
	}
}

sub _complete_up {
	my ($lei, @argv) = @_;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	map { $match_cb->($_) } PublicInbox::LeiSavedSearch::list($lei);
}

1;
