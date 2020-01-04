# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
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

use PublicInbox::SearchMsg;
use PublicInbox::MIME;
use PublicInbox::MID qw/id_compress/;
use PublicInbox::Over;
my $QP_FLAGS;
our %X = map { $_ => 0 } qw(BoolWeight Database Enquire
			NumberValueRangeProcessor QueryParser Stem);
our $Xap; # 'Search::Xapian' or 'Xapian'
my $ENQ_ASCENDING;

sub load_xapian () {
	return 1 if defined $Xap;
	for my $x (qw(Search::Xapian Xapian)) {
		eval "require $x";
		next if $@;

		$x->import(qw(:standard));
		$Xap = $x;
		$X{$_} = $Xap.'::'.$_ for (keys %X);

		# ENQ_ASCENDING doesn't seem exported by SWIG Xapian.pm,
		# so lets hope this part of the ABI is stable because it's
		# just an integer:
		$ENQ_ASCENDING = $x eq 'Xapian' ?
				1 : Search::Xapian::ENQ_ASCENDING();

		# for SearchMsg:
		*PublicInbox::SearchMsg::sortable_unserialise =
						$Xap.'::sortable_unserialise';
		# n.b. FLAG_PURE_NOT is expensive not suitable for a public
		# website as it could become a denial-of-service vector
		# FLAG_PHRASE also seems to cause performance problems chert
		# (and probably earlier Xapian DBs).  glass seems fine...
		# TODO: make this an option, maybe?
		# or make indexlevel=medium as default
		$QP_FLAGS = FLAG_PHRASE() | FLAG_BOOLEAN() | FLAG_LOVEHATE() |
				FLAG_WILDCARD();
		return 1;
	}
	undef;
}

# This is English-only, everything else is non-standard and may be confused as
# a prefix common in patch emails
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
	# 15 - see public-inbox-v2-format(5)
	#      further bumps likely unnecessary, we'll suggest in-place
	#      "--reindex" use for further fixes and tweaks
	SCHEMA_VERSION => 15,
};

my %bool_pfx_external = (
	mid => 'Q', # Message-ID (full/exact), this is mostly uniQue
	dfpre => 'XDFPRE',
	dfpost => 'XDFPOST',
	dfblob => 'XDFPRE XDFPOST',
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

sub xdir ($;$) {
	my ($self, $rdonly) = @_;
	if ($self->{version} == 1) {
		"$self->{inboxdir}/public-inbox/xapian" . SCHEMA_VERSION;
	} else {
		my $dir = "$self->{inboxdir}/xap" . SCHEMA_VERSION;
		return $dir if $rdonly;

		my $shard = $self->{shard};
		defined $shard or die "shard not given";
		$dir .= "/$shard";
	}
}

sub _xdb ($) {
	my ($self) = @_;
	my $dir = xdir($self, 1);
	my ($xdb, $slow_phrase);
	my $qpf = \($self->{qp_flags} ||= $QP_FLAGS);
	if ($self->{version} >= 2) {
		foreach my $shard (<$dir/*>) {
			-d $shard && $shard =~ m!/[0-9]+\z! or next;
			my $sub = $X{Database}->new($shard);
			if ($xdb) {
				$xdb->add_database($sub);
			} else {
				$xdb = $sub;
			}
			$slow_phrase ||= -f "$shard/iamchert";
		}
	} else {
		$slow_phrase = -f "$dir/iamchert";
		$xdb = $X{Database}->new($dir);
	}
	$$qpf |= FLAG_PHRASE() unless $slow_phrase;
	$xdb;
}

sub xdb ($) {
	my ($self) = @_;
	$self->{xdb} ||= do {
		load_xapian();
		_xdb($self);
	};
}

sub new {
	my ($class, $ibx) = @_;
	ref $ibx or die "BUG: expected PublicInbox::Inbox object: $ibx";
	my $self = bless {
		inboxdir => $ibx->{inboxdir},
		altid => $ibx->{altid},
		version => $ibx->{version} // 1,
	}, $class;
	my $dir = xdir($self, 1);
	$self->{over_ro} = PublicInbox::Over->new("$dir/over.sqlite3");
	$self;
}

sub reopen {
	my ($self) = @_;
	if (my $xdb = $self->{xdb}) {
		$xdb->reopen;
	}
	$self; # make chaining easier
}

# read-only
sub query {
	my ($self, $query_string, $opts) = @_;
	$opts ||= {};
	if ($query_string eq '' && !$opts->{mset}) {
		$self->{over_ro}->recent($opts);
	} else {
		my $qp = qp($self);
		my $qp_flags = $self->{qp_flags};
		my $query = $qp->parse_query($query_string, $qp_flags);
		$opts->{relevance} = 1 unless exists $opts->{relevance};
		_do_enquire($self, $query, $opts);
	}
}

sub retry_reopen {
	my ($self, $cb, $arg) = @_;
	for my $i (1..10) {
		if (wantarray) {
			my @ret;
			eval { @ret = $cb->($arg) };
			return @ret unless $@;
		} else {
			my $ret;
			eval { $ret = $cb->($arg) };
			return $ret unless $@;
		}
		# Exception: The revision being read has been discarded -
		# you should call Xapian::Database::reopen()
		if (ref($@) =~ /\bDatabaseModifiedError\b/) {
			warn "reopen try #$i on $@\n";
			reopen($self);
		} else {
			# let caller decide how to spew, because ExtMsg queries
			# get wonky and trigger:
			# "something terrible happened at .../Xapian/Enquire.pm"
			die;
		}
	}
	die "Too many Xapian database modifications in progress\n";
}

sub _do_enquire {
	my ($self, $query, $opts) = @_;
	retry_reopen($self, \&_enquire_once, [ $self, $query, $opts ]);
}

sub _enquire_once { # retry_reopen callback
	my ($self, $query, $opts) = @{$_[0]};
	my $xdb = xdb($self);
	my $enquire = $X{Enquire}->new($xdb);
	$enquire->set_query($query);
	$opts ||= {};
        my $desc = !$opts->{asc};
	if (($opts->{mset} || 0) == 2) {
		$enquire->set_docid_order($ENQ_ASCENDING);
		$enquire->set_weighting_scheme($X{BoolWeight}->new);
	} elsif ($opts->{relevance}) {
		$enquire->set_sort_by_relevance_then_value(TS, $desc);
	} else {
		$enquire->set_sort_by_value_then_relevance(TS, $desc);
	}
	my $offset = $opts->{offset} || 0;
	my $limit = $opts->{limit} || 50;
	my $mset = $enquire->get_mset($offset, $limit);
	return $mset if $opts->{mset};
	my @msgs = map { PublicInbox::SearchMsg::from_mitem($_) } $mset->items;
	return \@msgs unless wantarray;

	($mset->get_matches_estimated, \@msgs)
}

# read-write
sub stemmer { $X{Stem}->new($LANG) }

# read-only
sub qp {
	my ($self) = @_;

	my $qp = $self->{query_parser};
	return $qp if $qp;
	my $xdb = xdb($self);
	# new parser
	$qp = $X{QueryParser}->new;
	$qp->set_default_op(OP_AND());
	$qp->set_database($xdb);
	$qp->set_stemmer($self->stemmer);
	$qp->set_stemming_strategy(STEM_SOME());
	$qp->set_max_wildcard_expansion(100);
	my $nvrp = $X{NumberValueRangeProcessor};
	$qp->add_valuerangeprocessor($nvrp->new(YYYYMMDD, 'd:'));
	$qp->add_valuerangeprocessor($nvrp->new(DT, 'dt:'));

	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $_) foreach split(/ /, $prefix);
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
