# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::LeiSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::ExtSearch);
use PublicInbox::Search;

sub combined_docid ($$) {
	my ($self, $num) = @_;
	my $nshard = ($self->{nshard} // 1);
	($num - 1) * $nshard  + 1;
}

sub msg_keywords {
	my ($self, $num) = @_; # num_or_mitem
	my $xdb = $self->xdb; # set {nshard};
	my $docid = ref($num) ? $num->get_docid : do {
		# get combined docid from over.num:
		# (not generic Xapian, only works with our sharding scheme)
		my $nshard = $self->{nshard} // 1;
		($num - 1) * $nshard + $num % $nshard + 1;
	};
	my %kw;
	eval {
		my $end = $xdb->termlist_end($docid);
		my $cur = $xdb->termlist_begin($docid);
		for (; $cur != $end; $cur++) {
			$cur->skip_to('K');
			last if $cur == $end;
			my $kw = $cur->get_termname;
			$kw =~ s/\AK//s and $kw{$kw} = undef;
		}
	};
	warn "E: #$docid ($num): $@\n" if $@;
	wantarray ? sort(keys(%kw)) : \%kw;
}

1;
