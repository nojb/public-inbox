# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Read-only search interface for use by the web and NNTP interfaces
package PublicInbox::Search;
use strict;
use v5.10.1;
use parent qw(Exporter);
our @EXPORT_OK = qw(retry_reopen int_val get_pct xap_terms);
use List::Util qw(max);
use POSIX qw(strftime);
use Carp ();

# values for searching, changing the numeric value breaks
# compatibility with old indices (so don't change them it)
use constant {
	TS => 0, # Received: in Unix time (IMAP INTERNALDATE, JMAP receivedAt)
	YYYYMMDD => 1, # redundant with DT below
	DT => 2, # Date: YYYYMMDDHHMMSS (IMAP SENT*, JMAP sentAt)

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
our %X = map { $_ => 0 } qw(BoolWeight Database Enquire QueryParser Stem Query);
our $Xap; # 'Search::Xapian' or 'Xapian'
our $NVRP; # '$Xap::'.('NumberValueRangeProcessor' or 'NumberRangeProcessor')

# ENQ_DESCENDING and ENQ_ASCENDING weren't in SWIG Xapian.pm prior to 1.4.16,
# let's hope the ABI is stable
our $ENQ_DESCENDING = 0;
our $ENQ_ASCENDING = 1;

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

		*sortable_serialise = $x.'::sortable_serialise';
		*sortable_unserialise = $x.'::sortable_unserialise';
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
	patchid => 'XDFID',
);

my $non_quoted_body = 'XNQ XDFN XDFA XDFB XDFHH XDFCTX XDFPRE XDFPOST XDFID';
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
match date-time range, git "approxidate" formats supported
Open-ended ranges such as `d:last.week..' and
`d:..2.days.ago' are supported
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
	'patchid:' => "match `git patch-id --stable' output",
	'rt:' => <<EOF,
match received time, like `d:' if sender's clock was correct
EOF
);
chomp @HELP;

sub xdir ($;$) {
	my ($self, $rdonly) = @_;
	if ($rdonly || !defined($self->{shard})) {
		$self->{xpfx};
	} else { # v2 + extindex only:
		"$self->{xpfx}/$self->{shard}";
	}
}

# returns all shards as separate Xapian::Database objects w/o combining
sub xdb_shards_flat ($) {
	my ($self) = @_;
	my $xpfx = $self->{xpfx};
	my (@xdb, $slow_phrase);
	load_xapian();
	$self->{qp_flags} //= $QP_FLAGS;
	if ($xpfx =~ m!/xapian[0-9]+\z!) {
		@xdb = ($X{Database}->new($xpfx));
		$self->{qp_flags} |= FLAG_PHRASE() if !-f "$xpfx/iamchert";
	} else {
		opendir(my $dh, $xpfx) or return (); # not initialized yet
		# We need numeric sorting so shard[0] is first for reading
		# Xapian metadata, if needed
		my $last = max(grep(/\A[0-9]+\z/, readdir($dh))) // return ();
		for (0..$last) {
			my $shard_dir = "$self->{xpfx}/$_";
			push @xdb, $X{Database}->new($shard_dir);
			$slow_phrase ||= -f "$shard_dir/iamchert";
		}
		$self->{qp_flags} |= FLAG_PHRASE() if !$slow_phrase;
	}
	@xdb;
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
	my $nshard = $self->{nshard};
	[ map { mdocid($nshard, $_) } $mset->items ];
}

sub xdb ($) {
	my ($self) = @_;
	$self->{xdb} // do {
		my @xdb = $self->xdb_shards_flat or return;
		$self->{nshard} = scalar(@xdb);
		my $xdb = shift @xdb;
		$xdb->add_database($_) for @xdb;
		$self->{xdb} = $xdb;
	};
}

sub new {
	my ($class, $ibx) = @_;
	ref $ibx or die "BUG: expected PublicInbox::Inbox object: $ibx";
	my $xap = $ibx->version > 1 ? 'xap' : 'public-inbox/xapian';
	my $xpfx = "$ibx->{inboxdir}/$xap".SCHEMA_VERSION;
	my $self = bless { xpfx => $xpfx }, $class;
	$self->{altid} = $ibx->{altid} if defined($ibx->{altid});
	$self;
}

sub reopen {
	my ($self) = @_;
	if (my $xdb = $self->{xdb}) {
		$xdb->reopen;
	}
	$self; # make chaining easier
}

# Convert git "approxidate" ranges to something usable with our
# Xapian indices.  At the moment, Xapian only offers a C++-only API
# and neither the SWIG nor XS bindings allow us to use custom code
# to parse dates (and libgit2 doesn't expose git__date_parse, either,
# so we're running git-rev-parse(1)).
# This replaces things we need to send to $git->date_parse with
# "\0".$strftime_format.['+'|$idx]."\0" placeholders
sub date_parse_prepare {
	my ($to_parse, $pfx, $range) = @_;
	# are we inside a parenthesized statement?
	my $end = $range =~ s/([\)\s]*)\z// ? $1 : '';
	my @r = split(/\.\./, $range, 2);

	# expand "d:20101002" => "d:20101002..20101003" and like
	# n.b. git doesn't do YYYYMMDD w/o '-', it needs YYYY-MM-DD
	# We upgrade "d:" to "dt:" to iff using approxidate
	if ($pfx eq 'd') {
		my $fmt = "\0%Y%m%d";
		if (!defined($r[1])) {
			if ($r[0] =~ /\A([0-9]{4})([0-9]{2})([0-9]{2})\z/) {
				push @$to_parse, "$1-$2-$3";
				# we could've handled as-is, but we need
				# to parse anyways for "d+" below
			} else {
				push @$to_parse, $r[0];
				if ($r[0] !~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/) {
					$pfx = 'dt';
					$fmt = "\0%Y%m%d%H%M%S";
				}
			}
			$r[0] = "$fmt+$#$to_parse\0";
			$r[1] = "$fmt+\0";
		} else {
			for my $x (@r) {
				next if $x eq '' || $x =~ /\A[0-9]{8}\z/;
				push @$to_parse, $x;
				if ($x !~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/) {
					$pfx = 'dt';
				}
				$x = "$fmt$#$to_parse\0";
			}
			if ($pfx eq 'dt') {
				for (@r) {
					s/\0%Y%m%d/\0%Y%m%d%H%M%S/;
					s/\A([0-9]{8})\z/${1}000000/;
				}
			}
		}
	} elsif ($pfx eq 'dt') {
		if (!defined($r[1])) { # git needs gaps and not /\d{14}/
			if ($r[0] =~ /\A([0-9]{4})([0-9]{2})([0-9]{2})
					([0-9]{2})([0-9]{2})([0-9]{2})\z/x) {
				push @$to_parse, "$1-$2-$3 $4:$5:$6";
			} else {
				push @$to_parse, $r[0];
			}
			$r[0] = "\0%Y%m%d%H%M%S$#$to_parse\0";
			$r[1] = "\0%Y%m%d%H%M%S+\0";
		} else {
			for my $x (@r) {
				next if $x eq '' || $x =~ /\A[0-9]{14}\z/;
				push @$to_parse, $x;
				$x = "\0%Y%m%d%H%M%S$#$to_parse\0";
			}
		}
	} else { # "rt", let git interpret "YYYY", deal with Y10K later :P
		for my $x (@r) {
			next if $x eq '' || $x =~ /\A[0-9]{5,}\z/;
			push @$to_parse, $x;
			$x = "\0%s$#$to_parse\0";
		}
		$r[1] //= "\0%s+\0"; # add 1 day
	}
	"$pfx:".join('..', @r).$end;
}

sub date_parse_finalize {
	my ($git, $to_parse) = @_;
	# git-rev-parse can handle any number of args up to system
	# limits (around (4096*32) bytes on Linux).
	my @r = $git->date_parse(@$to_parse);
	# n.b. git respects TZ, times stored in SQLite/Xapian are always UTC,
	# and gmtime doesn't seem to do the right thing when TZ!=UTC
	my ($i, $t);
	$_[2] =~ s/\0(%[%YmdHMSs]+)([0-9\+]+)\0/
		$t = $2 eq '+' ? ($r[$i]+86400) : $r[$i=$2+0];
		$1 eq '%s' ? $t : strftime($1, gmtime($t))/sge;
}

# n.b. argv never has NUL, though we'll need to filter it out
# if this $argv isn't from a command execution
sub query_argv_to_string {
	my (undef, $git, $argv) = @_;
	my $to_parse;
	my $tmp = join(' ', map {;
		if (s!\b(d|rt|dt):(\S+)\z!date_parse_prepare(
						$to_parse //= [], $1, $2)!sge) {
			$_;
		} elsif (/\s/) {
			s/(.*?)\b(\w+:)// ? qq{$1$2"$_"} : qq{"$_"};
		} else {
			$_
		}
	} @$argv);
	date_parse_finalize($git, $to_parse, $tmp) if $to_parse;
	$tmp
}

# this is for the WWW "q=" query parameter and "lei q --stdin"
# it can't do d:"5 days ago", but it will do d:5.days.ago
sub query_approxidate {
	my (undef, $git) = @_; # $_[2] = $query_string (modified in-place)
	my $DQ = qq<"\x{201c}\x{201d}>; # Xapian can use curly quotes
	$_[2] =~ tr/\x00/ /; # Xapian doesn't do NUL, we use it as a placeholder
	my ($terms, $phrase, $to_parse);
	$_[2] =~ s{([^$DQ]*)([$DQ][^$DQ]*[$DQ])?}{
		($terms, $phrase) = ($1, $2);
		$terms =~ s!\b(d|rt|dt):(\S+)!
			date_parse_prepare($to_parse //= [], $1, $2)!sge;
		$terms.($phrase // '');
		}sge;
	date_parse_finalize($git, $to_parse, $_[2]) if $to_parse;
}

# read-only
sub mset {
	my ($self, $query_string, $opts) = @_;
	$opts ||= {};
	my $qp = $self->{qp} //= $self->qparse_new;
	my $query = $qp->parse_query($query_string, $self->{qp_flags});
	_do_enquire($self, $query, $opts);
}

sub retry_reopen {
	my ($self, $cb, @arg) = @_;
	for my $i (1..10) {
		if (wantarray) {
			my @ret = eval { $cb->($self, @arg) };
			return @ret unless $@;
		} else {
			my $ret = eval { $cb->($self, @arg) };
			return $ret unless $@;
		}
		# Exception: The revision being read has been discarded -
		# you should call Xapian::Database::reopen()
		if (ref($@) =~ /\bDatabaseModifiedError\b/) {
			reopen($self);
		} else {
			# let caller decide how to spew, because ExtMsg queries
			# get wonky and trigger:
			# "something terrible happened at .../Xapian/Enquire.pm"
			Carp::croak($@);
		}
	}
	Carp::croak("Too many Xapian database modifications in progress\n");
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
	if (defined(my $eidx_key = $opts->{eidx_key})) {
		$query = $X{Query}->new(OP_FILTER(), $query, 'O'.$eidx_key);
	}
	if (defined(my $uid_range = $opts->{uid_range})) {
		my $range = $X{Query}->new(OP_VALUE_RANGE(), UID,
					sortable_serialise($uid_range->[0]),
					sortable_serialise($uid_range->[1]));
		$query = $X{Query}->new(OP_FILTER(), $query, $range);
	}
	my $enquire = $X{Enquire}->new($xdb);
	$enquire->set_query($query);
	$opts ||= {};
	my $rel = $opts->{relevance} // 0;
	if ($rel == -2) { # ORDER BY docid/UID (highest first)
		$enquire->set_weighting_scheme($X{BoolWeight}->new);
		$enquire->set_docid_order($ENQ_DESCENDING);
	} elsif ($rel == -1) { # ORDER BY docid/UID (lowest first)
		$enquire->set_weighting_scheme($X{BoolWeight}->new);
		$enquire->set_docid_order($ENQ_ASCENDING);
	} elsif ($rel == 0) {
		$enquire->set_sort_by_value_then_relevance(TS, !$opts->{asc});
	} else { # rel > 0
		$enquire->set_sort_by_relevance_then_value(TS, !$opts->{asc});
	}

	# `mairix -t / --threads' or JMAP collapseThreads
	if ($opts->{threads} && has_threadid($self)) {
		$enquire->set_collapse_key(THREADID);
	}
	$enquire->get_mset($opts->{offset} || 0, $opts->{limit} || 50);
}

sub mset_to_smsg {
	my ($self, $ibx, $mset) = @_;
	my $nshard = $self->{nshard};
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
sub qparse_new {
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
	$cb->($qp, $NVRP->new(BYTES, 'z:'));
	$cb->($qp, $NVRP->new(TS, 'rt:'));
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
	$self->{qp} //= $self->qparse_new; # parse altids
	my @ret = @HELP;
	if (my $user_pfx = $self->{-user_pfx}) {
		push @ret, @$user_pfx;
	}
	\@ret;
}

# always returns a scalar value
sub int_val ($$) {
	my ($doc, $col) = @_;
	my $val = $doc->get_value($col) or return undef; # undef is '' in Xapian
	sortable_unserialise($val) + 0; # PV => IV conversion
}

sub get_pct ($) { # mset item
	# Capped at "99%" since "100%" takes an extra column in the
	# thread skeleton view.  <xapian/mset.h> says the value isn't
	# very meaningful, anyways.
	my $n = $_[0]->get_percent;
	$n > 99 ? 99 : $n;
}

sub xap_terms ($$;@) {
	my ($pfx, $xdb_or_doc, @docid) = @_; # @docid may be empty ()
	my %ret;
	my $end = $xdb_or_doc->termlist_end(@docid);
	my $cur = $xdb_or_doc->termlist_begin(@docid);
	for (; $cur != $end; $cur++) {
		$cur->skip_to($pfx);
		last if $cur == $end;
		my $tn = $cur->get_termname;
		$ret{substr($tn, length($pfx))} = undef if !index($tn, $pfx);
	}
	wantarray ? sort(keys(%ret)) : \%ret;
}

# get combined docid from over.num:
# (not generic Xapian, only works with our sharding scheme)
sub num2docid ($$) {
	my ($self, $num) = @_;
	my $nshard = $self->{nshard};
	($num - 1) * $nshard + $num % $nshard + 1;
}

1;
