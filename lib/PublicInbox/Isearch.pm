# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provides everything the PublicInbox::Search object does;
# but uses global ExtSearch (->ALL) with an eidx_key query to
# emulate per-Inbox search using ->ALL.
package PublicInbox::Isearch;
use strict;
use v5.10.1;
use PublicInbox::ExtSearch;
use PublicInbox::Search;

sub new {
	my (undef, $ibx, $es) = @_;
	bless { es => $es, eidx_key => $ibx->eidx_key }, __PACKAGE__;
}

sub _ibx_id ($) {
	my ($self) = @_;
	my $sth = $self->{es}->over->dbh->prepare_cached(<<'', undef, 1);
SELECT ibx_id FROM inboxes WHERE eidx_key = ? LIMIT 1

	$sth->execute($self->{eidx_key});
	$sth->fetchrow_array //
		die "E: `$self->{eidx_key}' not in $self->{es}->{topdir}\n";
}

sub query_approxidate { $_[0]->{es}->query_approxidate($_[1], $_[2]) }

sub mset {
	my ($self, $str, $opt) = @_;
	my %opt = $opt ? %$opt : ();
	$opt{eidx_key} = $self->{eidx_key};
	if (my $uid_range = $opt{uid_range}) {
		my ($beg, $end) = @$uid_range;
		my $ibx_id = $self->{-ibx_id} //= _ibx_id($self);
		my $dbh = $self->{es}->over->dbh;
		my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT MIN(docid) FROM xref3 WHERE ibx_id = ? AND xnum >= ? AND xnum <= ?

		$sth->execute($ibx_id, $beg, $end);
		my @r = ($sth->fetchrow_array);

		$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT MAX(docid) FROM xref3 WHERE ibx_id = ? AND xnum >= ? AND xnum <= ?

		$sth->execute($ibx_id, $beg, $end);
		$r[1] = $sth->fetchrow_array;
		if (defined($r[1]) && defined($r[0])) {
			$opt{limit} = $r[1] - $r[0] + 1;
		} else {
			$r[1] //= 0xffffffff;
			$r[0] //= 0;
		}
		$opt{uid_range} = \@r;
	}
	$self->{es}->mset($str, \%opt);
}

sub mset_to_artnums {
	my ($self, $mset, $opt) = @_;
	my $docids = PublicInbox::Search::mset_to_artnums($self->{es}, $mset);
	my $ibx_id = $self->{-ibx_id} //= _ibx_id($self);
	my $qmarks = join(',', map { '?' } @$docids);
	if ($opt && ($opt->{relevance} // 0) == -1) { # -1 => ENQ_ASCENDING
		my $range = '';
		my @r;
		if (my $r = $opt->{uid_range}) {
			$range = 'AND xnum >= ? AND xnum <= ?';
			@r = @$r;
		}
		return $self->{es}->over->dbh->
			selectcol_arrayref(<<"", undef, $ibx_id, @$docids, @r);
SELECT xnum FROM xref3 WHERE ibx_id = ? AND docid IN ($qmarks) $range
ORDER BY xnum ASC

	}

	my $rows = $self->{es}->over->dbh->
			selectall_arrayref(<<"", undef, $ibx_id, @$docids);
SELECT docid,xnum FROM xref3 WHERE ibx_id = ? AND docid IN ($qmarks)

	my $i = -1;
	my %order = map { $_ => ++$i } @$docids;
	my @xnums;
	for my $row (@$rows) { # @row = ($docid, $xnum)
		my $idx = delete($order{$row->[0]}) // next;
		$xnums[$idx] = $row->[1];
	}
	if (scalar keys %order) {
		warn "W: $self->{es}->{topdir} #",
			join(', ', sort { $a <=> $b } keys %order),
			" not mapped to `$self->{eidx_key}'\n";
		warn "W: $self->{es}->{topdir} may need to be reindexed\n";
		@xnums = grep { defined } @xnums;
	}
	\@xnums;
}

sub mset_to_smsg {
	my ($self, $ibx, $mset) = @_; # $ibx is a real inbox, not eidx
	my $xnums = mset_to_artnums($self, $mset);
	my $i = -1;
	my %order = map { $_ => ++$i } @$xnums;
	my $unordered = $ibx->over->get_all(@$xnums);
	my @msgs;
	for my $smsg (@$unordered) {
		my $idx = delete($order{$smsg->{num}}) // do {
			warn "W: $ibx->{inboxdir} #$smsg->{num}\n";
			next;
		};
		$msgs[$idx] = $smsg;
	}
	if (scalar keys %order) {
		warn "W: $ibx->{inboxdir} #",
			join(', ', sort { $a <=> $b } keys %order),
			" no longer valid\n";
		warn "W: $self->{es}->{topdir} may need to be reindexed\n";
	}
	wantarray ? ($mset->get_matches_estimated, \@msgs) : \@msgs;
}

sub has_threadid { 1 }

sub help { $_[0]->{es}->help }

1;
