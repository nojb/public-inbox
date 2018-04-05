# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Read-only search interface for use by the web and NNTP interfaces
package PublicInbox::Search;
use strict;
use warnings;

# values for searching
use constant TS => 0;  # Received: header in Unix time
use constant YYYYMMDD => 1; # Date: header for searching in the WWW UI
use constant DT => 2; # Date: YYYYMMDDHHMMSS

use Search::Xapian qw/:standard/;
use PublicInbox::SearchMsg;
use PublicInbox::MIME;
use PublicInbox::MID qw/id_compress/;
use PublicInbox::Over;

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
	SCHEMA_VERSION => 15,

	# n.b. FLAG_PURE_NOT is expensive not suitable for a public website
	# as it could become a denial-of-service vector
	QP_FLAGS => FLAG_PHRASE|FLAG_BOOLEAN|FLAG_LOVEHATE|FLAG_WILDCARD,
};

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
	'dt:' => <<EOF,
date-time range as YYYYMMDDhhmmss (e.g. dt:19931002011000..19931002011200)
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
	my $dir;
	if ($version >= 2) {
		$dir = "$self->{mainrepo}/xap" . SCHEMA_VERSION;
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
	} else {
		$dir = $self->xdir;
		$self->{xdb} = Search::Xapian::Database->new($dir);
	}
	$self->{over_ro} = PublicInbox::Over->new("$dir/over.sqlite3");
	$self;
}

sub reopen {
	my ($self) = @_;
	$self->{xdb}->reopen;
	$self; # make chaining easier
}

# read-only
sub query {
	my ($self, $query_string, $opts) = @_;
	$opts ||= {};
	if ($query_string eq '' && !$opts->{mset}) {
		$self->{over_ro}->recent($opts);
	} else {
		my $query = $self->qp->parse_query($query_string, QP_FLAGS);
		$opts->{relevance} = 1 unless exists $opts->{relevance};
		_do_enquire($self, $query, $opts);
	}
}

sub get_thread {
	my ($self, $mid, $prev) = @_;
	$self->{over_ro}->get_thread($mid, $prev);
}

sub retry_reopen {
	my ($self, $cb) = @_;
	for my $i (1..10) {
		if (wantarray) {
			my @ret;
			eval { @ret = $cb->() };
			return @ret unless $@;
		} else {
			my $ret;
			eval { $ret = $cb->() };
			return $ret unless $@;
		}
		# Exception: The revision being read has been discarded -
		# you should call Xapian::Database::reopen()
		if (ref($@) eq 'Search::Xapian::DatabaseModifiedError') {
			warn "reopen try #$i on $@\n";
			reopen($self);
		} else {
			warn "ref: ", ref($@), "\n";
			die;
		}
	}
	die "Too many Xapian database modifications in progress\n";
}

sub _do_enquire {
	my ($self, $query, $opts) = @_;
	retry_reopen($self, sub { _enquire_once($self, $query, $opts) });
}

sub _enquire_once {
	my ($self, $query, $opts) = @_;
	my $enquire = enquire($self);
	$enquire->set_query($query);
	$opts ||= {};
        my $desc = !$opts->{asc};
	if (($opts->{mset} || 0) == 2) {
		$enquire->set_docid_order(Search::Xapian::ENQ_ASCENDING());
		$enquire->set_weighting_scheme(Search::Xapian::BoolWeight->new);
		delete $self->{enquire};
	} elsif ($opts->{relevance}) {
		$enquire->set_sort_by_relevance_then_value(TS, $desc);
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
	return \@msgs unless wantarray;

	($mset->get_matches_estimated, \@msgs)
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
	$qp->add_valuerangeprocessor(
		Search::Xapian::NumberValueRangeProcessor->new(DT, 'dt:'));

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

# only used for NNTP server
sub query_xover {
	my ($self, $beg, $end, $offset) = @_;
	$self->{over_ro}->query_xover($beg, $end, $offset);
}

sub query_ts {
	my ($self, $ts, $prev) = @_;
	$self->{over_ro}->query_ts($ts, $prev);
}

sub first_smsg_by_mid {
	my ($self, $mid) = @_;
	my $smsg;
	retry_reopen($self, sub {
		each_smsg_by_mid($self, $mid, sub { $smsg = $_[0]; undef });
	});
	$smsg;
}

sub lookup_article {
	my ($self, $num) = @_;
	my $term = 'XNUM'.$num;
	my $db = $self->{xdb};
	retry_reopen($self, sub {
		my $head = $db->postlist_begin($term);
		my $tail = $db->postlist_end($term);
		return if $head->equal($tail);
		my $doc_id = $head->get_docid;
		return unless defined $doc_id;
		$head->inc;
		if ($head->nequal($tail)) {
			warn "article #$num is not unique\n";
		}
		# raises on error:
		my $doc = $db->get_document($doc_id);
		my $smsg = PublicInbox::SearchMsg->wrap($doc);
		$smsg->{doc_id} = $doc_id;
		$smsg->load_expand;
	});
}

sub each_smsg_by_mid {
	my ($self, $mid, $cb) = @_;
	# XXX retry_reopen isn't necessary for V2Writable, but the PSGI
	# interface will need it...
	my $db = $self->{xdb};
	my $term = 'Q' . $mid;
	my $head = $db->postlist_begin($term);
	my $tail = $db->postlist_end($term);
	if ($head == $tail) {
		$db->reopen;
		$head = $db->postlist_begin($term);
		$tail = $db->postlist_end($term);
	}
	return ($head, $tail, $db) if wantarray;
	for (; $head->nequal($tail); $head->inc) {
		my $doc_id = $head->get_docid;
		my $doc = $db->get_document($doc_id);
		my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->{doc_id} = $doc_id;
		$cb->($smsg) or return;
	}
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
