# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::LeiSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::ExtSearch);
use PublicInbox::Search qw(xap_terms);

# get combined docid from over.num:
# (not generic Xapian, only works with our sharding scheme)
sub num2docid ($$) {
	my ($self, $num) = @_;
	my $nshard = $self->{nshard};
	($num - 1) * $nshard + $num % $nshard + 1;
}

sub msg_keywords {
	my ($self, $num) = @_; # num_or_mitem
	my $xdb = $self->xdb; # set {nshard};
	my $docid = ref($num) ? $num->get_docid : num2docid($self, $num);
	my $kw = xap_terms('K', $xdb, $docid);
	warn "E: #$docid ($num): $@\n" if $@;
	wantarray ? sort(keys(%$kw)) : $kw;
}

1;
