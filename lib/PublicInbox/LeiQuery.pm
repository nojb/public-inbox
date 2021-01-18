# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles lei <q|ls-query|rm-query|mv-query> commands
package PublicInbox::LeiQuery;
use strict;
use v5.10.1;
use PublicInbox::DS qw(dwaitpid);

sub _vivify_external { # _externals_each callback
	my ($src, $dir) = @_;
	if (-f "$dir/ei.lock") {
		require PublicInbox::ExtSearch;
		push @$src, PublicInbox::ExtSearch->new($dir);
	} elsif (-f "$dir/inbox.lock" || -d "$dir/public-inbox") { # v2, v1
		require PublicInbox::Inbox;
		push @$src, bless { inboxdir => $dir }, 'PublicInbox::Inbox';
	} else {
		warn "W: ignoring $dir, unable to determine type\n";
	}
}

# the main "lei q SEARCH_TERMS" method
sub lei_q {
	my ($self, @argv) = @_;
	my $opt = $self->{opt};

	# --local is enabled by default
	# src: LeiXSearch || LeiSearch || Inbox
	my @srcs;
	require PublicInbox::LeiXSearch;
	require PublicInbox::LeiOverview;
	PublicInbox::Config->json;
	my $lxs = PublicInbox::LeiXSearch->new;

	# --external is enabled by default, but allow --no-external
	if ($opt->{external} // 1) {
		$self->_externals_each(\&_vivify_external, \@srcs);
	}
	my $j = $opt->{jobs} // (scalar(@srcs) > 3 ? 3 : scalar(@srcs));
	$j = 1 if !$opt->{thread};
	$j++ if $opt->{'local'}; # for sto->search below
	$self->atfork_prepare_wq($lxs);
	$lxs->wq_workers_start('lei_xsearch', $j, $self->oldset);
	$self->{lxs} = $lxs;

	my $ovv = PublicInbox::LeiOverview->new($self) or return;
	if (my $l2m = $self->{l2m}) {
		$j = 4 if $j <= 4; # TODO configurable
		$self->atfork_prepare_wq($l2m);
		$l2m->wq_workers_start('lei2mail', $j, $self->oldset);
	}

	# no forking workers after this
	my $sto = $self->_lei_store(1);
	unshift(@srcs, $sto->search) if $opt->{'local'};
	my %mset_opt = map { $_ => $opt->{$_} } qw(thread limit offset);
	$mset_opt{asc} = $opt->{'reverse'} ? 1 : 0;
	$mset_opt{qstr} = join(' ', map {;
		# Consider spaces in argv to be for phrase search in Xapian.
		# In other words, the users should need only care about
		# normal shell quotes and not have to learn Xapian quoting.
		/\s/ ? (s/\A(\w+:)// ? qq{$1"$_"} : qq{"$_"}) : $_
	} @argv);
	if (defined(my $sort = $opt->{'sort'})) {
		if ($sort eq 'relevance') {
			$mset_opt{relevance} = 1;
		} elsif ($sort eq 'docid') {
			$mset_opt{relevance} = $mset_opt{asc} ? -1 : -2;
		} elsif ($sort =~ /\Areceived(?:-?[aA]t)?\z/) {
			# the default
		} else {
			die "unrecognized --sort=$sort\n";
		}
	}
	# descending docid order
	$mset_opt{relevance} //= -2 if $opt->{thread};
	$self->{mset_opt} = \%mset_opt;
	$ovv->ovv_begin($self);
	$lxs->do_query($self, \@srcs);
}

1;
