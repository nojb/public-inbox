# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used by PublicInbox::SearchView
package PublicInbox::SearchQuery;
use strict;
use v5.10.1;
use URI::Escape qw(uri_escape);
use PublicInbox::MID qw(MID_ESC);
our $LIM = 200;

sub new {
	my ($class, $qp) = @_;

	my $r = $qp->{r}; # relevance
	my $t = $qp->{t}; # collapse threads
	my ($l) = (($qp->{l} || '') =~ /([0-9]+)/);
	$l = $LIM if !$l || $l > $LIM;
	bless {
		q => $qp->{'q'},
		x => $qp->{x} || '',
		o => (($qp->{o} || '0') =~ /(-?[0-9]+)/),
		l => $l,
		r => (defined $r && $r ne '0'),
		t => (defined $t && $t ne '0'),
	}, $class;
}

sub qs_html {
	my ($self, %override) = @_;

	if (scalar(keys(%override))) {
		$self = bless { (%$self, %override) }, ref($self);
	}

	my $q = uri_escape($self->{'q'}, MID_ESC);
	$q =~ s/%20/+/g; # improve URL readability
	my $qs = "q=$q";

	if (my $o = $self->{o}) { # ignore o == 0
		$qs .= "&amp;o=$o";
	}
	if (my $l = $self->{l}) {
		$qs .= "&amp;l=$l" unless $l == $LIM;
	}
	for my $bool (qw(r t)) {
		$qs .= "&amp;$bool" if $self->{$bool};
	}
	if (my $x = $self->{x}) {
		$qs .= "&amp;x=$x" if ($x eq 't' || $x eq 'A' || $x eq 'm');
	}
	$qs;
}

1;
