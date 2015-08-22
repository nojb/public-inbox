# Copyright (C) 2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# based on notmuch, but with no concept of folders, files or flags
package PublicInbox::Search;
use strict;
use warnings;
use PublicInbox::SearchMsg;
use Search::Xapian qw/:standard/;
use Email::MIME;
use PublicInbox::MID qw/mid_clean mid_compressed/;

# This is English-only, everything else is non-standard and may be confused as
# a prefix common in patch emails
our $REPLY_RE = qr/^re:\s+/i;
our $LANG = 'english';

use constant {
	TS => 0,
	# SCHEMA_VERSION history
	# 0 - initial
	# 1 - subject_path is lower-cased
	# 2 - subject_path is mid_compressed in the index, only
	# 3 - message-ID is compressed if it includes '%' (hack!)
	# 4 - change "Re: " normalization, avoid circular Reference ghosts
	# 5 - subject_path drops trailing '.'
	# 6 - preserve References: order in document data
	SCHEMA_VERSION => 6,
	QP_FLAGS => FLAG_PHRASE|FLAG_BOOLEAN|FLAG_LOVEHATE|FLAG_WILDCARD,
};

# setup prefixes
my %bool_pfx_internal = (
	type => 'T', # "mail" or "ghost"
	mid => 'Q', # uniQue id (Message-ID or mid_compressed)
);

my %bool_pfx_external = (
	path => 'XPATH',
	thread => 'G', # newsGroup (or similar entity - e.g. a web forum name)
	references => 'XREFS',
	inreplyto => 'XIRT',
);

my %prob_prefix = (
	subject => 'S',
);

my %all_pfx = (%bool_pfx_internal, %bool_pfx_external, %prob_prefix);

sub xpfx { $all_pfx{$_[0]} }

our %PFX2TERM_RMAP;
my %meta_pfx = (mid => 1, thread => 1, path => 1, type => 1);
while (my ($k, $v) = each %all_pfx) {
	$PFX2TERM_RMAP{$v} = $k if $meta_pfx{$k};
}

my $mail_query = Search::Xapian::Query->new(xpfx('type') . 'mail');

sub xdir {
	my (undef, $git_dir) = @_;
	"$git_dir/public-inbox/xapian" . SCHEMA_VERSION;
}

sub new {
	my ($class, $git_dir) = @_;
	my $dir = $class->xdir($git_dir);
	my $db = Search::Xapian::Database->new($dir);
	bless { xdb => $db, git_dir => $git_dir }, $class;
}

sub reopen { $_[0]->{xdb}->reopen }

# read-only
sub query {
	my ($self, $query_string, $opts) = @_;
	my $query = $self->qp->parse_query($query_string, QP_FLAGS);

	$self->do_enquire($query, $opts);
}

sub get_subject_path {
	my ($self, $path, $opts) = @_;
	my $query = $self->qp->parse_query("path:".mid_compressed($path), 0);
	$self->do_enquire($query, $opts);
}

# given a message ID, get followups to a message
sub get_followups {
	my ($self, $mid, $opts) = @_;
	$mid = mid_clean($mid);
	$mid = mid_compressed($mid);
	my $qp = $self->qp;
	my $irt = $qp->parse_query("inreplyto:$mid", 0);
	my $ref = $qp->parse_query("references:$mid", 0);
	my $query = Search::Xapian::Query->new(OP_OR, $irt, $ref);
	$self->do_enquire($query, $opts);
}

sub get_thread {
	my ($self, $mid, $opts) = @_;
	my $smsg = eval { $self->lookup_message($mid) };

	return { total => 0, msgs => [] } unless $smsg;
	my $qp = $self->qp;
	my $qtid = $qp->parse_query('thread:'.$smsg->thread_id, 0);
	my $qsub = $qp->parse_query('path:'.mid_compressed($smsg->path), 0);
	my $query = Search::Xapian::Query->new(OP_OR, $qtid, $qsub);
	$self->do_enquire($query, $opts);
}

# private subs below

sub do_enquire {
	my ($self, $query, $opts) = @_;
	my $enquire = $self->enquire;

	$query = Search::Xapian::Query->new(OP_AND, $query, $mail_query);
	$enquire->set_query($query);
	$enquire->set_sort_by_relevance_then_value(TS, 0);
	$opts ||= {};
	my $offset = $opts->{offset} || 0;
	my $limit = $opts->{limit} || 50;
	my $mset = $enquire->get_mset($offset, $limit);
	my @msgs = map {
		PublicInbox::SearchMsg->load_doc($_->get_document);
	} $mset->items;

	{ total => $mset->get_matches_estimated, msgs => \@msgs }
}

# read-write
sub stemmer { Search::Xapian::Stem->new($LANG) }

# read-only
sub qp {
	my ($self) = @_;

	my $qp = $self->{query_parser};
	return $qp if $qp;

	# new parser
	$qp = Search::Xapian::QueryParser->new;
	$qp->set_default_op(OP_AND);
	$qp->set_database($self->{xdb});
	$qp->set_stemmer($self->stemmer);
	$qp->set_stemming_strategy(STEM_SOME);
	$qp->add_valuerangeprocessor($self->ts_range_processor);
	$qp->add_valuerangeprocessor($self->date_range_processor);

	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $prefix);
	}

	while (my ($name, $prefix) = each %prob_prefix) {
		$qp->add_prefix($name, $prefix);
	}

	$self->{query_parser} = $qp;
}

sub ts_range_processor {
	$_[0]->{tsrp} ||= Search::Xapian::NumberValueRangeProcessor->new(TS);
}

sub date_range_processor {
	$_[0]->{drp} ||= Search::Xapian::DateValueRangeProcessor->new(TS);
}

sub lookup_message {
	my ($self, $mid) = @_;
	$mid = mid_clean($mid);
	$mid = mid_compressed($mid);

	my $doc_id = $self->find_unique_doc_id('mid', $mid);
	my $smsg;
	if (defined $doc_id) {
		# raises on error:
		my $doc = $self->{xdb}->get_document($doc_id);
		$smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->doc_id($doc_id);
	}
	$smsg;
}

sub find_unique_doc_id {
	my ($self, $term, $value) = @_;

	my ($begin, $end) = $self->find_doc_ids($term, $value);

	return undef if $begin->equal($end); # not found

	my $rv = $begin->get_docid;

	# sanity check
	$begin->inc;
	$begin->equal($end) or die "Term '$term:$value' is not unique\n";
	$rv;
}

# returns begin and end PostingIterator
sub find_doc_ids {
	my ($self, $term, $value) = @_;

	$self->find_doc_ids_for_term(xpfx($term) . $value);
}

# returns begin and end PostingIterator
sub find_doc_ids_for_term {
	my ($self, $term) = @_;
	my $db = $self->{xdb};

	($db->postlist_begin($term), $db->postlist_end($term));
}

# normalize subjects so they are suitable as pathnames for URLs
sub subject_path {
	my $subj = pop;
	$subj = subject_normalized($subj);
	$subj =~ s![^a-zA-Z0-9_\.~/\-]+!_!g;
	lc($subj);
}

sub subject_normalized {
	my $subj = pop;
	$subj =~ s/\A\s+//s; # no leading space
	$subj =~ s/\s+\z//s; # no trailing space
	$subj =~ s/\s+/ /gs; # no redundant spaces
	$subj =~ s/\.+\z//; # no trailing '.'
	$subj =~ s/$REPLY_RE//igo; # remove reply prefix
	$subj;
}

sub enquire {
	my ($self) = @_;
	$self->{enquire} ||= Search::Xapian::Enquire->new($self->{xdb});
}

1;
