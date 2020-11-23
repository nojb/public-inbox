# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# read-only counterpart to MiscIdx
package PublicInbox::MiscSearch;
use strict;
use v5.10.1;
use PublicInbox::Search qw(retry_reopen);

# Xapian value columns:
our $MODIFIED = 0;

# avoid conflicting with message Search::prob_prefix for UI/UX reasons
my %PROB_PREFIX = (
	description => 'S', # $INBOX_DIR/description
	address => 'A',
	listid => 'XLISTID',
	url => 'XURL',
	infourl => 'XINFOURL',
	name => 'XNAME',
	'' => 'S A XLISTID XNAME XURL XINFOURL'
);

sub new {
	my ($class, $dir) = @_;
	bless {
		xdb => $PublicInbox::Search::X{Database}->new($dir)
	}, $class;
}

# read-only
sub mi_qp_new ($) {
	my ($self) = @_;
	my $xdb = $self->{xdb};
	my $qp = $PublicInbox::Search::X{QueryParser}->new;
	$qp->set_default_op(PublicInbox::Search::OP_AND());
	$qp->set_database($xdb);
	$qp->set_stemmer(PublicInbox::Search::stemmer($self));
	$qp->set_stemming_strategy(PublicInbox::Search::STEM_SOME());
	my $cb = $qp->can('set_max_wildcard_expansion') //
		$qp->can('set_max_expansion'); # Xapian 1.5.0+
	$cb->($qp, 100);
	$cb = $qp->can('add_valuerangeprocessor') //
		$qp->can('add_rangeprocessor'); # Xapian 1.5.0+
	while (my ($name, $prefix) = each %PROB_PREFIX) {
		$qp->add_prefix($name, $_) for split(/ /, $prefix);
	}
	$qp->add_boolean_prefix('type', 'T');
	$qp;
}

sub misc_enquire_once { # retry_reopen callback
	my ($self, $qr, $opt) = @{$_[0]};
	my $eq = $PublicInbox::Search::X{Enquire}->new($self->{xdb});
	$eq->set_query($qr);
        my $desc = !$opt->{asc};
	my $rel = $opt->{relevance} // 0;
	if ($rel == -1) { # ORDER BY docid/UID
		$eq->set_docid_order($PublicInbox::Search::ENQ_ASCENDING);
		$eq->set_weighting_scheme($PublicInbox::Search::X{BoolWeight}->new);
	} elsif ($rel) {
		$eq->set_sort_by_relevance_then_value($MODIFIED, $desc);
	} else {
		$eq->set_sort_by_value_then_relevance($MODIFIED, $desc);
	}
	$eq->get_mset($opt->{offset} || 0, $opt->{limit} || 200);
}

sub mset {
	my ($self, $qs, $opt) = @_;
	$opt ||= {};
	my $qp = $self->{qp} //= mi_qp_new($self);
	$qs = 'type:inbox' if $qs eq '';
	my $qr = $qp->parse_query($qs, $PublicInbox::Search::QP_FLAGS);
	$opt->{relevance} = 1 unless exists $opt->{relevance};
	retry_reopen($self, \&misc_enquire_once, [ $self, $qr, $opt ]);
}

1;
