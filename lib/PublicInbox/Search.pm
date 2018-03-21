# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Read-only search interface for use by the web and NNTP interfaces
package PublicInbox::Search;
use strict;
use warnings;

# values for searching
use constant DS => 0; # Date: header in Unix time
use constant NUM => 1; # NNTP article number
use constant BYTES => 2; # :bytes as defined in RFC 3977
use constant LINES => 3; # :lines as defined in RFC 3977
use constant TS => 4;  # Received: header in Unix time
use constant YYYYMMDD => 5; # for searching in the WWW UI

use Search::Xapian qw/:standard/;
use PublicInbox::SearchMsg;
use PublicInbox::MIME;
use PublicInbox::MID qw/mid_clean id_compress/;

# This is English-only, everything else is non-standard and may be confused as
# a prefix common in patch emails
our $REPLY_RE = qr/^re:\s+/i;
our $LANG = 'english';

use constant {
	# SCHEMA_VERSION history
	# 0 - initial
	# 1 - subject_path is lower-cased
	# 2 - subject_path is id_compress in the index, only
	# 3 - message-ID is compressed if it includes '%' (hack!)
	# 4 - change "Re: " normalization, avoid circular Reference ghosts
	# 5 - subject_path drops trailing '.'
	# 6 - preserve References: order in document data
	# 7 - remove references and inreplyto terms
	# 8 - remove redundant/unneeded document data
	# 9 - disable Message-ID compression (SHA-1)
	# 10 - optimize doc for NNTP overviews
	# 11 - merge threads when vivifying ghosts
	# 12 - change YYYYMMDD value column to numeric
	# 13 - fix threading for empty References/In-Reply-To
	#      (commit 83425ef12e4b65cdcecd11ddcb38175d4a91d5a0)
	# 14 - fix ghost root vivification
	SCHEMA_VERSION => 14,

	# n.b. FLAG_PURE_NOT is expensive not suitable for a public website
	# as it could become a denial-of-service vector
	QP_FLAGS => FLAG_PHRASE|FLAG_BOOLEAN|FLAG_LOVEHATE|FLAG_WILDCARD,
};

# setup prefixes
my %bool_pfx_internal = (
	type => 'T', # "mail" or "ghost"
	thread => 'G', # newsGroup (or similar entity - e.g. a web forum name)
);

my %bool_pfx_external = (
	mid => 'Q', # Message-ID (full/exact), this is mostly uniQue
);

my $non_quoted_body = 'XNQ XDFN XDFA XDFB XDFHH XDFCTX XDFPRE XDFPOST';
my %prob_prefix = (
	# for mairix compatibility
	s => 'S',
	m => 'XM', # 'mid:' (bool) is exact, 'm:' (prob) can do partial
	f => 'A',
	t => 'XTO',
	tc => 'XTO XCC',
	c => 'XCC',
	tcf => 'XTO XCC A',
	a => 'XTO XCC A',
	b => $non_quoted_body . ' XQUOT',
	bs => $non_quoted_body . ' XQUOT S',
	n => 'XFN',

	q => 'XQUOT',
	nq => $non_quoted_body,
	dfn => 'XDFN',
	dfa => 'XDFA',
	dfb => 'XDFB',
	dfhh => 'XDFHH',
	dfctx => 'XDFCTX',
	dfpre => 'XDFPRE',
	dfpost => 'XDFPOST',
	dfblob => 'XDFPRE XDFPOST',

	# default:
	'' => 'XM S A XQUOT XFN ' . $non_quoted_body,
);

# not documenting m: and mid: for now, the using the URLs works w/o Xapian
our @HELP = (
	's:' => 'match within Subject  e.g. s:"a quick brown fox"',
	'd:' => <<EOF,
date range as YYYYMMDD  e.g. d:19931002..20101002
Open-ended ranges such as d:19931002.. and d:..20101002
are also supported
EOF
	'b:' => 'match within message body, including text attachments',
	'nq:' => 'match non-quoted text within message body',
	'q:' => 'match quoted text within message body',
	'n:' => 'match filename of attachment(s)',
	't:' => 'match within the To header',
	'c:' => 'match within the Cc header',
	'f:' => 'match within the From header',
	'a:' => 'match within the To, Cc, and From headers',
	'tc:' => 'match within the To and Cc headers',
	'bs:' => 'match within the Subject and body',
	'dfn:' => 'match filename from diff',
	'dfa:' => 'match diff removed (-) lines',
	'dfb:' => 'match diff added (+) lines',
	'dfhh:' => 'match diff hunk header context (usually a function name)',
	'dfctx:' => 'match diff context lines',
	'dfpre:' => 'match pre-image git blob ID',
	'dfpost:' => 'match post-image git blob ID',
	'dfblob:' => 'match either pre or post-image git blob ID',
);
chomp @HELP;

my $mail_query = Search::Xapian::Query->new('T' . 'mail');

sub xdir {
	my ($self) = @_;
	if ($self->{version} == 1) {
		"$self->{mainrepo}/public-inbox/xapian" . SCHEMA_VERSION;
	} else {
		my $dir = "$self->{mainrepo}/xap" . SCHEMA_VERSION;
		my $part = $self->{partition};
		defined $part or die "partition not given";
		$dir .= "/$part";
	}
}

sub new {
	my ($class, $mainrepo, $altid) = @_;
	my $version = 1;
	my $ibx = $mainrepo;
	if (ref $ibx) {
		$version = $ibx->{version} || 1;
		$mainrepo = $ibx->{mainrepo};
	}
	my $self = bless {
		mainrepo => $mainrepo,
		altid => $altid,
		version => $version,
	}, $class;
	if ($version >= 2) {
		my $dir = "$self->{mainrepo}/xap" . SCHEMA_VERSION;
		my $xdb;
		my $parts = 0;
		foreach my $part (<$dir/*>) {
			-d $part && $part =~ m!/\d+\z! or next;
			$parts++;
			my $sub = Search::Xapian::Database->new($part);
			if ($xdb) {
				$xdb->add_database($sub);
			} else {
				$xdb = $sub;
			}
		}
		$self->{xdb} = $xdb;
		$self->{skel} = Search::Xapian::Database->new("$dir/skel");
	} else {
		$self->{xdb} = Search::Xapian::Database->new($self->xdir);
	}
	$self;
}

sub reopen {
	my ($self) = @_;
	$self->{xdb}->reopen;
	if (my $skel = $self->{skel}) {
		$skel->reopen;
	}
	$self; # make chaining easier
}

# read-only
sub query {
	my ($self, $query_string, $opts) = @_;
	my $query;

	$opts ||= {};
	unless ($query_string eq '') {
		$query = $self->qp->parse_query($query_string, QP_FLAGS);
		$opts->{relevance} = 1 unless exists $opts->{relevance};
	}

	_do_enquire($self, $query, $opts);
}

sub get_thread {
	my ($self, $mid, $opts) = @_;
	my $smsg = retry_reopen($self, sub { lookup_skeleton($self, $mid) });

	return { total => 0, msgs => [] } unless $smsg;
	my $qtid = Search::Xapian::Query->new('G' . $smsg->thread_id);
	my $path = $smsg->path;
	if (defined $path && $path ne '') {
		my $path = id_compress($smsg->path);
		my $qsub = Search::Xapian::Query->new('XPATH' . $path);
		$qtid = Search::Xapian::Query->new(OP_OR, $qtid, $qsub);
	}
	$opts ||= {};
	$opts->{limit} ||= 1000;

	# always sort threads by timestamp, this makes life easier
	# for the threading algorithm (in SearchThread.pm)
	$opts->{asc} = 1;
	$opts->{enquire} = enquire_skel($self);
	_do_enquire($self, $qtid, $opts);
}

sub retry_reopen {
	my ($self, $cb) = @_;
	my $ret;
	for (1..10) {
		eval { $ret = $cb->() };
		return $ret unless $@;
		# Exception: The revision being read has been discarded -
		# you should call Xapian::Database::reopen()
		if (ref($@) eq 'Search::Xapian::DatabaseModifiedError') {
			reopen($self);
		} else {
			warn "ref: ", ref($@), "\n";
			die;
		}
	}
}

sub _do_enquire {
	my ($self, $query, $opts) = @_;
	retry_reopen($self, sub { _enquire_once($self, $query, $opts) });
}

sub _enquire_once {
	my ($self, $query, $opts) = @_;
	my $enquire = $opts->{enquire} || enquire($self);
	if (defined $query) {
		$query = Search::Xapian::Query->new(OP_AND,$query,$mail_query);
	} else {
		$query = $mail_query;
	}
	$enquire->set_query($query);
	$opts ||= {};
        my $desc = !$opts->{asc};
	if ($opts->{relevance}) {
		$enquire->set_sort_by_relevance_then_value(TS, $desc);
	} elsif ($opts->{num}) {
		$enquire->set_sort_by_value(NUM, 0);
	} else {
		$enquire->set_sort_by_value_then_relevance(TS, $desc);
	}
	my $offset = $opts->{offset} || 0;
	my $limit = $opts->{limit} || 50;
	my $mset = $enquire->get_mset($offset, $limit);
	return $mset if $opts->{mset};
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
	$qp->add_valuerangeprocessor(
		Search::Xapian::NumberValueRangeProcessor->new(YYYYMMDD, 'd:'));

	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $prefix);
	}

	# we do not actually create AltId objects,
	# just parse the spec to avoid the extra DB handles for now.
	if (my $altid = $self->{altid}) {
		my $user_pfx = $self->{-user_pfx} ||= [];
		for (@$altid) {
			# $_ = 'serial:gmane:/path/to/gmane.msgmap.sqlite3'
			/\Aserial:(\w+):/ or next;
			my $pfx = $1;
			push @$user_pfx, "$pfx:", <<EOF;
alternate serial number  e.g. $pfx:12345 (boolean)
EOF
			# gmane => XGMANE
			$qp->add_boolean_prefix($pfx, 'X'.uc($pfx));
		}
		chomp @$user_pfx;
	}

	while (my ($name, $prefix) = each %prob_prefix) {
		$qp->add_prefix($name, $_) foreach split(/ /, $prefix);
	}

	$self->{query_parser} = $qp;
}

sub num_range_processor {
	$_[0]->{nrp} ||= Search::Xapian::NumberValueRangeProcessor->new(NUM);
}

# only used for NNTP server
sub query_xover {
	my ($self, $beg, $end, $offset) = @_;
	my $qp = Search::Xapian::QueryParser->new;
	$qp->set_database($self->{skel} || $self->{xdb});
	$qp->add_valuerangeprocessor($self->num_range_processor);
	my $query = $qp->parse_query("$beg..$end", QP_FLAGS);

	my $opts = {
		enquire => enquire_skel($self),
		num => 1,
		limit => 200,
		offset => $offset,
	};
	_do_enquire($self, $query, $opts);
}

sub query_ts {
	my ($self, $ts, $opts) = @_;
	my $qp = $self->{qp_ts} ||= eval {
		my $q = Search::Xapian::QueryParser->new;
		$q->set_database($self->{skel} || $self->{xdb});
		$q->add_valuerangeprocessor(
			Search::Xapian::NumberValueRangeProcessor->new(TS));
		$q
	};
	my $query = $qp->parse_query($ts, QP_FLAGS);
	$opts->{enquire} = enquire_skel($self);
	_do_enquire($self, $query, $opts);
}

sub lookup_skeleton {
	my ($self, $mid) = @_;
	my $skel = $self->{skel} or return lookup_message($self, $mid);
	$mid = mid_clean($mid);
	my $term = 'Q' . $mid;
	my $smsg;
	my $beg = $skel->postlist_begin($term);
	if ($beg != $skel->postlist_end($term)) {
		my $doc_id = $beg->get_docid;
		if (defined $doc_id) {
			# raises on error:
			my $doc = $skel->get_document($doc_id);
			$smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
			$smsg->{doc_id} = $doc_id;
		}
	}
	$smsg;
}

sub lookup_message {
	my ($self, $mid) = @_;
	$mid = mid_clean($mid);

	my $doc_id = $self->find_first_doc_id('Q' . $mid);
	my $smsg;
	if (defined $doc_id) {
		# raises on error:
		my $doc = $self->{xdb}->get_document($doc_id);
		$smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->{doc_id} = $doc_id;
	}
	$smsg;
}

sub lookup_mail { # no ghosts!
	my ($self, $mid) = @_;
	retry_reopen($self, sub {
		my $smsg = lookup_skeleton($self, $mid) or return;
		$smsg->load_expand;
	});
}

sub lookup_article {
	my ($self, $num) = @_;
	my $term = 'XNUM'.$num;
	my $smsg;
	eval {
		retry_reopen($self, sub {
			my $db = $self->{skel} || $self->{xdb};
			my $head = $db->postlist_begin($term);
			return if $head == $db->postlist_end($term);
			my $doc_id = $head->get_docid;
			return unless defined $doc_id;
			# raises on error:
			my $doc = $db->get_document($doc_id);
			$smsg = PublicInbox::SearchMsg->wrap($doc);
			$smsg->load_expand;
			$smsg->{doc_id} = $doc_id;
		});
	};
	$smsg;
}

sub each_smsg_by_mid {
	my ($self, $mid, $cb) = @_;
	# XXX retry_reopen isn't necessary for V2Writable, but the PSGI
	# interface will need it...
	my $db = $self->{skel} || $self->{xdb};
	my $term = 'Q' . $mid;
	my $head = $db->postlist_begin($term);
	my $tail = $db->postlist_end($term);
	for (; $head->nequal($tail); $head->inc) {
		my $doc_id = $head->get_docid;
		my $doc = $db->get_document($doc_id);
		my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->{doc_id} = $doc_id;
		$cb->($smsg) or return;
	}
}

sub find_unique_doc_id {
	my ($self, $termval) = @_;

	my ($begin, $end) = $self->find_doc_ids($termval);

	return undef if $begin->equal($end); # not found

	my $rv = $begin->get_docid;

	# sanity check
	$begin->inc;
	$begin->equal($end) or die "Term '$termval' is not unique\n";
	$rv;
}

# returns begin and end PostingIterator
sub find_doc_ids {
	my ($self, $termval) = @_;
	my $db = $self->{xdb};

	($db->postlist_begin($termval), $db->postlist_end($termval));
}

sub find_first_doc_id {
	my ($self, $termval) = @_;

	my ($begin, $end) = $self->find_doc_ids($termval);

	return undef if $begin->equal($end); # not found

	$begin->get_docid;
}

# normalize subjects so they are suitable as pathnames for URLs
# XXX: consider for removal
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

sub enquire_skel {
	my ($self) = @_;
	if (my $skel = $self->{skel}) {
		$self->{enquire_skel} ||= Search::Xapian::Enquire->new($skel);
	} else {
		enquire($self);
	}
}

sub help {
	my ($self) = @_;
	$self->qp; # parse altids
	my @ret = @HELP;
	if (my $user_pfx = $self->{-user_pfx}) {
		push @ret, @$user_pfx;
	}
	\@ret;
}

1;
