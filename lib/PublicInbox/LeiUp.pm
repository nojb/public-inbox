# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei up" - updates the result of "lei q --save"
package PublicInbox::LeiUp;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use PublicInbox::LeiOverview;

sub lei_up {
	my ($lei, $out) = @_;
	$lei->{lse} = $lei->_lei_store(1)->search;
	my $lss = PublicInbox::LeiSavedSearch->new($lei, $out) or return;
	my $mset_opt = $lei->{mset_opt} = { relevance => -2 };
	$mset_opt->{limit} = $lei->{opt}->{limit} // 10000;
	my $q = $mset_opt->{q_raw} = $lss->{-cfg}->{'lei.q'} //
				return $lei->fail("lei.q unset in $lss->{-f}");
	my $lse = $lei->{lse} // die 'BUG: {lse} missing';
	if (ref($q)) {
		$mset_opt->{qstr} = $lse->query_argv_to_string($lse->git, $q);
	} else {
		$lse->query_approxidate($lse->git, $mset_opt->{qstr} = $q);
	}
	$lei->{opt}->{output} = $lss->{-cfg}->{'lei.q.output'} //
		return $lei->fail("lei.q.output unset in $lss->{-f}");

	my $to_avref = $lss->{-cfg}->can('_array');
	for my $k (qw(only include exclude)) {
		my $v = $lss->{-cfg}->{"lei.q.$k"} // next;
		$lei->{opt}->{$k} = $to_avref->($v);
	}
	for my $k (qw(external local remote
			import-remote import-before threads)) {
		my $v = $lss->{-cfg}->{"lei.q.$k"} // next;
		$lei->{opt}->{$k} = $v;
	}
	$lei->{lss} = $lss; # for LeiOverview->new
	my $lxs = $lei->lxs_prepare or return;
	$lei->ale->refresh_externals($lxs);
	$lei->{opt}->{save} = 1;
	$lei->_start_query;
}

sub _complete_up {
	my ($lei, @argv) = @_;
	my ($cur, $re) = $lei->complete_url_common(\@argv);
	grep(/\A$re\Q$cur/, PublicInbox::LeiSavedSearch::list($lei));
}

1;
