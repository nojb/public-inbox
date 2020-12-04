# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Read-only search interface for use by the web and NNTP interfaces
package PublicInbox::Search;
use strict;
use parent qw(Exporter);
our @EXPORT_OK = qw(retry_reopen);
use List::Util qw(max);

# values for searching, changing the numeric value breaks
# compatibility with old indices (so don't change them it)
use constant {
	TS => 0, # Received: header in Unix time (IMAP INTERNALDATE)
	YYYYMMDD => 1, # Date: header for searching in the WWW UI
	DT => 2, # Date: YYYYMMDDHHMMSS

	# added for public-inbox 1.6.0+
	BYTES => 3, # IMAP RFC822.SIZE
	UID => 4, # IMAP UID == NNTP article number == Xapian docid
	THREADID => 5, # RFC 8474, RFC 8621

	# TODO
	# REPLYCNT => ?, # IMAP ANSWERED

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
	#      "--reindex" use for further fixes and tweaks:
	#
	#      public-inbox v1.5.0 adds (still SCHEMA_VERSION=15):
	#      * "lid:" and "l:" for List-Id searches
	#
	#      v1.6.0 adds BYTES, UID and THREADID values
	SCHEMA_VERSION => 15,
};

use PublicInbox::Smsg;
use PublicInbox::Over;
our $QP_FLAGS;
our %X = map { $_ => 0 } qw(BoolWeight Database Enquire QueryParser Stem);
our $Xap; # 'Search::Xapian' or 'Xapian'
our $NVRP; # '$Xap::'.('NumberValueRangeProcessor' or 'NumberRangeProcessor')
our $ENQ_ASCENDING;

sub load_xapian () {
	return 1 if defined $Xap;
	# n.b. PI_XAPIAN is intended for development use only.  We still
	# favor Search::Xapian since that's what's available in current
	# Debian stable (10.x) and derived distros.
	for my $x (($ENV{PI_XAPIAN} // 'Search::Xapian'), 'Xapian') {
		eval "require $x";
		next if $@;

		$x->import(qw(:standard));
		$Xap = $x;

		# `version_string' was added in Xapian 1.1
		my $xver = eval('v'.eval($x.'::version_string()')) //
				eval('v'.eval($x.'::xapian_version_string()'));

		# NumberRangeProcessor was added in Xapian 1.3.6,
		# NumberValueRangeProcessor was removed for 1.5.0+,
		# favor the older /Value/ variant since that's what our
		# (currently) preferred Search::Xapian supports
		$NVRP = $x.'::'.($x eq 'Xapian' && $xver ge v1.5 ?
			'NumberRangeProcessor' : 'NumberValueRangeProcessor');
		$X{$_} = $Xap.'::'.$_ for (keys %X);

		# ENQ_ASCENDING doesn't seem exported by SWIG Xapian.pm,
		# so lets hope this part of the ABI is stable because it's
		# just an integer:
		$ENQ_ASCENDING = $x eq 'Xapian' ?
				1 : Search::Xapian::ENQ_ASCENDING();

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

# note: the non-X term prefix allocations are shared with
# Xapian omega, see xapian-applications/omega/docs/termprefixes.rst
my %bool_pfx_external = (
	mid => 'Q', # Message-ID (full/exact), this is mostly uniQue
	lid => 'G', # newsGroup (or similar entity), just inside <>
	dfpre => 'XDFPRE',
	dfpost => 'XDFPOST',
	dfblob => 'XDFPRE XDFPOST',
);

my $non_quoted_body = 'XNQ XDFN XDFA XDFB XDFHH XDFCTX XDFPRE XDFPOST';
my %prob_prefix = (
	# for mairix compatibility
	s => 'S',
	m => 'XM', # 'mid:' (bool) is exact, 'm:' (prob) can do partial
	l => 'XL', # 'lid:' (bool) is exact, 'l:' (prob) can do partial
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
# not documenting lid: for now, either, it is probably redundant with l:,
# especially since we don't offer boolean searches for To/Cc/From
# headers, either
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
	'l:' => 'match contents of the List-Id header',
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
	if ($rdonly || !defined($self->{shard})) {
		$self->{xpfx};
	} else { # v2 only:
		"$self->{xpfx}/$self->{shard}";
	}
}

sub xdb_sharded {
	my ($self) = @_;
	opendir(my $dh, $self->{xpfx}) or return; # not initialized yet

	# We need numeric sorting so shard[0] is first for reading
	# Xapian metadata, if needed
	my $last = max(grep(/\A[0-9]+\z/, readdir($dh)));
	return if !defined($last);
	my (@xdb, $slow_phrase);
	for (0..$last) {
		my $shard_dir = "$self->{xpfx}/$_";
		if (-d $shard_dir && -r _) {
			push @xdb, $X{Database}->new($shard_dir);
			$slow_phrase ||= -f "$shard_dir/iamchert";
		} else { # gaps from missing epochs throw off mdocid()
			warn "E: $shard_dir missing or unreadable\n";
			return;
		}
	}
	$self->{qp_flags} |= FLAG_PHRASE() if !$slow_phrase;
	$self->{nshard} = scalar(@xdb);
	my $xdb = shift @xdb;
	$xdb->add_database($_) for @xdb;
	$xdb;
}

sub _xdb {
	my ($self) = @_;
	my $dir = xdir($self, 1);
	$self->{qp_flags} //= $QP_FLAGS;
	if ($self->{ibx_ver} >= 2) {
		xdb_sharded($self);
	} else {
		$self->{qp_flags} |= FLAG_PHRASE() if !-f "$dir/iamchert";
		$X{Database}->new($dir);
	}
}

# v2 Xapian docids don't conflict, so they're identical to
# NNTP article numbers and IMAP UIDs.
# https://trac.xapian.org/wiki/FAQ/MultiDatabaseDocumentID
sub mdocid {
	my ($nshard, $mitem) = @_;
	my $docid = $mitem->get_docid;
	int(($docid - 1) / $nshard) + 1;
}

sub mset_to_artnums {
	my ($self, $mset) = @_;
	my $nshard = $self->{nshard} // 1;
	[ map { mdocid($nshard, $_) } $mset->items ];
}

sub xdb ($) {
	my ($self) = @_;
	$self->{xdb} //= do {
		load_xapian();
		$self->_xdb;
	};
}

sub xpfx_init ($) {
	my ($self) = @_;
	if ($self->{ibx_ver} == 1) {
		$self->{xpfx} .= '/public-inbox/xapian' . SCHEMA_VERSION;
	} else {
		$self->{xpfx} .= '/xap'.SCHEMA_VERSION;
	}
}

sub new {
	my ($class, $ibx) = @_;
	ref $ibx or die "BUG: expected PublicInbox::Inbox object: $ibx";
	my $self = bless {
		xpfx => $ibx->{inboxdir}, # for xpfx_init
		altid => $ibx->{altid},
		ibx_ver => $ibx->version,
	}, $class;
	xpfx_init($self);
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
sub mset {
	my ($self, $query_string, $opts) = @_;
	$opts ||= {};
	my $qp = $self->{qp} //= qparse_new($self);
	my $query = $qp->parse_query($query_string, $self->{qp_flags});
	$opts->{relevance} = 1 unless exists $opts->{relevance};
	_do_enquire($self, $query, $opts);
}

sub retry_reopen {
	my ($self, $cb, @arg) = @_;
	for my $i (1..10) {
		if (wantarray) {
			my @ret;
			eval { @ret = $cb->($self, @arg) };
			return @ret unless $@;
		} else {
			my $ret;
			eval { $ret = $cb->($self, @arg) };
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
	retry_reopen($self, \&_enquire_once, $query, $opts);
}

# returns true if all docs have the THREADID value
sub has_threadid ($) {
	my ($self) = @_;
	(xdb($self)->get_metadata('has_threadid') // '') eq '1';
}

sub _enquire_once { # retry_reopen callback
	my ($self, $query, $opts) = @_;
	my $xdb = xdb($self);
	my $enquire = $X{Enquire}->new($xdb);
	$enquire->set_query($query);
	$opts ||= {};
        my $desc = !$opts->{asc};
	if (($opts->{mset} || 0) == 2) { # mset == 2: ORDER BY docid/UID
		$enquire->set_docid_order($ENQ_ASCENDING);
		$enquire->set_weighting_scheme($X{BoolWeight}->new);
	} elsif ($opts->{relevance}) {
		$enquire->set_sort_by_relevance_then_value(TS, $desc);
	} else {
		$enquire->set_sort_by_value_then_relevance(TS, $desc);
	}

	# `mairix -t / --threads' or JMAP collapseThreads
	if ($opts->{thread} && has_threadid($self)) {
		$enquire->set_collapse_key(THREADID);
	}
	$enquire->get_mset($opts->{offset} || 0, $opts->{limit} || 50);
}

sub mset_to_smsg {
	my ($self, $ibx, $mset) = @_;
	my $nshard = $self->{nshard} // 1;
	my $i = 0;
	my %order = map { mdocid($nshard, $_) => ++$i } $mset->items;
	my @msgs = sort {
		$order{$a->{num}} <=> $order{$b->{num}}
	} @{$ibx->over->get_all(keys %order)};
	wantarray ? ($mset->get_matches_estimated, \@msgs) : \@msgs;
}

# read-write
sub stemmer { $X{Stem}->new($LANG) }

# read-only
sub qparse_new ($) {
	my ($self) = @_;

	my $xdb = xdb($self);
	my $qp = $X{QueryParser}->new;
	$qp->set_default_op(OP_AND());
	$qp->set_database($xdb);
	$qp->set_stemmer(stemmer($self));
	$qp->set_stemming_strategy(STEM_SOME());
	my $cb = $qp->can('set_max_wildcard_expansion') //
		$qp->can('set_max_expansion'); # Xapian 1.5.0+
	$cb->($qp, 100);
	$cb = $qp->can('add_valuerangeprocessor') //
		$qp->can('add_rangeprocessor'); # Xapian 1.5.0+
	$cb->($qp, $NVRP->new(YYYYMMDD, 'd:'));
	$cb->($qp, $NVRP->new(DT, 'dt:'));

	# for IMAP, undocumented for WWW and may be split off go away
	$cb->($qp, $NVRP->new(BYTES, 'bytes:'));
	$cb->($qp, $NVRP->new(TS, 'ts:'));
	$cb->($qp, $NVRP->new(UID, 'uid:'));

	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $_) foreach split(/ /, $prefix);
	}

	# we do not actually create AltId objects,
	# just parse the spec to avoid the extra DB handles for now.
	if (my $altid = $self->{altid}) {
		my $user_pfx = $self->{-user_pfx} = [];
		for (@$altid) {
			# $_ = 'serial:gmane:/path/to/gmane.msgmap.sqlite3'
			# note: Xapian supports multibyte UTF-8, /^[0-9]+$/,
			# and '_' with prefixes matching \w+
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
	$qp;
}

sub help {
	my ($self) = @_;
	$self->{qp} //= qparse_new($self); # parse altids
	my @ret = @HELP;
	if (my $user_pfx = $self->{-user_pfx}) {
		push @ret, @$user_pfx;
	}
	\@ret;
}

1;
