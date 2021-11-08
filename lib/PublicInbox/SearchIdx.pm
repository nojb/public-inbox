# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files
#
# Indexes mail with Xapian and our (SQLite-based) ::Msgmap for use
# with the web and NNTP interfaces.  This index maintains thread
# relationships for use by PublicInbox::SearchThread.
# This writes to the search index.
package PublicInbox::SearchIdx;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Search PublicInbox::Lock Exporter);
use PublicInbox::Eml;
use PublicInbox::Search qw(xap_terms);
use PublicInbox::InboxWritable;
use PublicInbox::MID qw(mids_for_index mids);
use PublicInbox::MsgIter;
use PublicInbox::IdxStack;
use Carp qw(croak carp);
use POSIX qw(strftime);
use Time::Local qw(timegm);
use PublicInbox::OverIdx;
use PublicInbox::Spawn qw(spawn nodatacow_dir);
use PublicInbox::Git qw(git_unquote);
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);
use PublicInbox::Address;
use Config;
our @EXPORT_OK = qw(log2stack is_ancestor check_size prepare_stack
	index_text term_generator add_val is_bad_blob);
my $X = \%PublicInbox::Search::X;
our ($DB_CREATE_OR_OPEN, $DB_OPEN);
our $DB_NO_SYNC = 0;
our $BATCH_BYTES = $ENV{XAPIAN_FLUSH_THRESHOLD} ? 0x7fffffff :
	# assume a typical 64-bit system has 8x more RAM than a
	# typical 32-bit system:
	(($Config{ptrsize} >= 8 ? 8192 : 1024) * 1024);

use constant DEBUG => !!$ENV{DEBUG};

my $xapianlevels = qr/\A(?:full|medium)\z/;
my $hex = '[a-f0-9]';
my $OID = $hex .'{40,}';
my @VMD_MAP = (kw => 'K', L => 'L');
our $INDEXLEVELS = qr/\A(?:full|medium|basic)\z/;

sub new {
	my ($class, $ibx, $creat, $shard) = @_;
	ref $ibx or die "BUG: expected PublicInbox::Inbox object: $ibx";
	my $inboxdir = $ibx->{inboxdir};
	my $version = $ibx->version;
	my $indexlevel = 'full';
	my $altid = $ibx->{altid};
	if ($altid) {
		require PublicInbox::AltId;
		$altid = [ map { PublicInbox::AltId->new($ibx, $_); } @$altid ];
	}
	if ($ibx->{indexlevel}) {
		if ($ibx->{indexlevel} =~ $INDEXLEVELS) {
			$indexlevel = $ibx->{indexlevel};
		} else {
			die("Invalid indexlevel $ibx->{indexlevel}\n");
		}
	}
	$ibx = PublicInbox::InboxWritable->new($ibx);
	my $self = PublicInbox::Search->new($ibx);
	bless $self, $class;
	$self->{ibx} = $ibx;
	$self->{-altid} = $altid;
	$self->{indexlevel} = $indexlevel;
	$self->{-set_indexlevel_once} = 1 if $indexlevel eq 'medium';
	if ($ibx->{-skip_docdata}) {
		$self->{-set_skip_docdata_once} = 1;
		$self->{-skip_docdata} = 1;
	}
	if ($version == 1) {
		$self->{lock_path} = "$inboxdir/ssoma.lock";
		my $dir = $self->xdir;
		$self->{oidx} = PublicInbox::OverIdx->new("$dir/over.sqlite3");
		$self->{oidx}->{-no_fsync} = 1 if $ibx->{-no_fsync};
	} elsif ($version == 2) {
		defined $shard or die "shard is required for v2\n";
		# shard is a number
		$self->{shard} = $shard;
		$self->{lock_path} = undef;
	} else {
		die "unsupported inbox version=$version\n";
	}
	$self->{creat} = ($creat || 0) == 1;
	$self;
}

sub need_xapian ($) { $_[0]->{indexlevel} =~ $xapianlevels }

sub idx_release {
	my ($self, $wake) = @_;
	if (need_xapian($self)) {
		my $xdb = delete $self->{xdb} or croak '{xdb} not acquired';
		$xdb->close;
	}
	$self->lock_release($wake) if $self->{creat};
	undef;
}

sub load_xapian_writable () {
	return 1 if $X->{WritableDatabase};
	PublicInbox::Search::load_xapian() or die "failed to load Xapian: $@\n";
	my $xap = $PublicInbox::Search::Xap;
	for (qw(Document TermGenerator WritableDatabase)) {
		$X->{$_} = $xap.'::'.$_;
	}
	eval 'require '.$X->{WritableDatabase} or die;
	*sortable_serialise = $xap.'::sortable_serialise';
	$DB_CREATE_OR_OPEN = eval($xap.'::DB_CREATE_OR_OPEN()');
	$DB_OPEN = eval($xap.'::DB_OPEN()');
	my $ver = (eval($xap.'::major_version()') << 16) |
		(eval($xap.'::minor_version()') << 8) |
		eval($xap.'::revision()');
	$DB_NO_SYNC = 0x4 if $ver >= 0x10400;
	# Xapian v1.2.21..v1.2.24 were missing close-on-exec on OFD locks
	$X->{CLOEXEC_UNSET} = 1 if $ver >= 0x010215 && $ver <= 0x010218;
	1;
}

sub idx_acquire {
	my ($self) = @_;
	my $flag;
	my $dir = $self->xdir;
	if (need_xapian($self)) {
		croak 'already acquired' if $self->{xdb};
		load_xapian_writable();
		$flag = $self->{creat} ? $DB_CREATE_OR_OPEN : $DB_OPEN;
	}
	if ($self->{creat}) {
		require File::Path;
		$self->lock_acquire;

		# don't create empty Xapian directories if we don't need Xapian
		my $is_shard = defined($self->{shard});
		if (!-d $dir && (!$is_shard ||
				($is_shard && need_xapian($self)))) {
			File::Path::mkpath($dir);
			nodatacow_dir($dir);
			$self->{-set_has_threadid_once} = 1;
		}
	}
	return unless defined $flag;
	$flag |= $DB_NO_SYNC if ($self->{ibx} // $self->{eidx})->{-no_fsync};
	my $xdb = eval { ($X->{WritableDatabase})->new($dir, $flag) };
	croak "Failed opening $dir: $@" if $@;
	$self->{xdb} = $xdb;
}

sub add_val ($$$) {
	my ($doc, $col, $num) = @_;
	$num = sortable_serialise($num);
	$doc->add_value($col, $num);
}

sub term_generator ($) { # write-only
	my ($self) = @_;

	$self->{term_generator} //= do {
		my $tg = $X->{TermGenerator}->new;
		$tg->set_stemmer(PublicInbox::Search::stemmer($self));
		$tg;
	}
}

sub index_phrase ($$$$) {
	my ($self, $text, $wdf_inc, $prefix) = @_;

	my $tg = term_generator($self);
	$tg->index_text($text, $wdf_inc, $prefix);
	$tg->increase_termpos;
}

sub index_text ($$$$) {
	my ($self, $text, $wdf_inc, $prefix) = @_;

	if ($self->{indexlevel} eq 'full') {
		index_phrase($self, $text, $wdf_inc, $prefix);
	} else {
		my $tg = term_generator($self);
		$tg->index_text_without_positions($text, $wdf_inc, $prefix);
	}
}

sub index_headers ($$) {
	my ($self, $smsg) = @_;
	my @x = (from => 'A', to => 'XTO', cc => 'XCC'); # A: Author
	while (my ($field, $pfx) = splice(@x, 0, 2)) {
		my $val = $smsg->{$field};
		next if $val eq '';
		# include "(comments)" after the address, too, so not using
		# PublicInbox::Address::names or pairs
		index_text($self, $val, 1, $pfx);

		# we need positional info for email addresses since they
		# can be considered phrases
		if ($self->{indexlevel} eq 'medium') {
			for my $addr (PublicInbox::Address::emails($val)) {
				index_phrase($self, $addr, 1, $pfx);
			}
		}
	}
	@x = (subject => 'S');
	while (my ($field, $pfx) = splice(@x, 0, 2)) {
		my $val = $smsg->{$field};
		index_text($self, $val, 1, $pfx) if $val ne '';
	}
}

sub index_diff_inc ($$$$) {
	my ($self, $text, $pfx, $xnq) = @_;
	if (@$xnq) {
		index_text($self, join("\n", @$xnq), 1, 'XNQ');
		@$xnq = ();
	}
	if ($pfx eq 'XDFN') {
		index_phrase($self, $text, 1, $pfx);
	} else {
		index_text($self, $text, 1, $pfx);
	}
}

sub index_old_diff_fn {
	my ($self, $seen, $fa, $fb, $xnq) = @_;

	# no renames or space support for traditional diffs,
	# find the number of leading common paths to strip:
	my @fa = split('/', $fa);
	my @fb = split('/', $fb);
	while (scalar(@fa) && scalar(@fb)) {
		$fa = join('/', @fa);
		$fb = join('/', @fb);
		if ($fa eq $fb) {
			unless ($seen->{$fa}++) {
				index_diff_inc($self, $fa, 'XDFN', $xnq);
			}
			return 1;
		}
		shift @fa;
		shift @fb;
	}
	0;
}

sub index_diff ($$$) {
	my ($self, $txt, $doc) = @_;
	my %seen;
	my $in_diff;
	my @xnq;
	my $xnq = \@xnq;
	foreach (split(/\n/, $txt)) {
		if ($in_diff && s/^ //) { # diff context
			index_diff_inc($self, $_, 'XDFCTX', $xnq);
		} elsif (/^-- $/) { # email signature begins
			$in_diff = undef;
		} elsif (m!^diff --git "?[^/]+/.+ "?[^/]+/.+\z!) {
			# wait until "---" and "+++" to capture filenames
			$in_diff = 1;
			push @xnq, $_;
		# traditional diff:
		} elsif (m/^diff -(.+) (\S+) (\S+)$/) {
			my ($opt, $fa, $fb) = ($1, $2, $3);
			push @xnq, $_;
			# only support unified:
			next unless $opt =~ /[uU]/;
			$in_diff = index_old_diff_fn($self, \%seen, $fa, $fb,
							$xnq);
		} elsif (m!^--- ("?[^/]+/.+)!) {
			my $fn = $1;
			$fn = (split('/', git_unquote($fn), 2))[1];
			$seen{$fn}++ or index_diff_inc($self, $fn, 'XDFN', $xnq);
			$in_diff = 1;
		} elsif (m!^\+\+\+ ("?[^/]+/.+)!)  {
			my $fn = $1;
			$fn = (split('/', git_unquote($fn), 2))[1];
			$seen{$fn}++ or index_diff_inc($self, $fn, 'XDFN', $xnq);
			$in_diff = 1;
		} elsif (/^--- (\S+)/) {
			$in_diff = $1;
			push @xnq, $_;
		} elsif (defined $in_diff && /^\+\+\+ (\S+)/) {
			$in_diff = index_old_diff_fn($self, \%seen, $in_diff,
							$1, $xnq);
		} elsif ($in_diff && s/^\+//) { # diff added
			index_diff_inc($self, $_, 'XDFB', $xnq);
		} elsif ($in_diff && s/^-//) { # diff removed
			index_diff_inc($self, $_, 'XDFA', $xnq);
		} elsif (m!^index ([a-f0-9]+)\.\.([a-f0-9]+)!) {
			my ($ba, $bb) = ($1, $2);
			index_git_blob_id($doc, 'XDFPRE', $ba);
			index_git_blob_id($doc, 'XDFPOST', $bb);
			$in_diff = 1;
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*$/) {
			# traditional diff w/o -p
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*(\S+.*)$/) {
			# hunk header context
			index_diff_inc($self, $1, 'XDFHH', $xnq);
		# ignore the following lines:
		} elsif (/^(?:dis)similarity index/ ||
				/^(?:old|new) mode/ ||
				/^(?:deleted|new) file mode/ ||
				/^(?:copy|rename) (?:from|to) / ||
				/^(?:dis)?similarity index / ||
				/^\\ No newline at end of file/ ||
				/^Binary files .* differ/) {
			push @xnq, $_;
		} elsif ($_ eq '') {
			# possible to be in diff context, some mail may be
			# stripped by MUA or even GNU diff(1).  "git apply"
			# treats a bare "\n" as diff context, too
		} else {
			push @xnq, $_;
			warn "non-diff line: $_\n" if DEBUG && $_ ne '';
			$in_diff = undef;
		}
	}

	index_text($self, join("\n", @xnq), 1, 'XNQ');
}

sub index_xapian { # msg_iter callback
	my $part = $_[0]->[0]; # ignore $depth and $idx
	my ($self, $doc) = @{$_[1]};
	my $ct = $part->content_type || 'text/plain';
	my $fn = $part->filename;
	if (defined $fn && $fn ne '') {
		index_phrase($self, $fn, 1, 'XFN');
	}
	if ($part->{is_submsg}) {
		my $mids = mids_for_index($part);
		index_ids($self, $doc, $part, $mids);
		my $smsg = bless {}, 'PublicInbox::Smsg';
		$smsg->populate($part);
		index_headers($self, $smsg);
	}

	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;
	$_[0]->[0] = $part = undef; # free memory

	# split off quoted and unquoted blocks:
	my @sections = PublicInbox::MsgIter::split_quotes($s);
	undef $s; # free memory
	for my $txt (@sections) {
		if ($txt =~ /\A>/) {
			index_text($self, $txt, 0, 'XQUOT');
		} else {
			# does it look like a diff?
			if ($txt =~ /^(?:diff|---|\+\+\+) /ms) {
				index_diff($self, $txt, $doc);
			} else {
				index_text($self, $txt, 1, 'XNQ');
			}
		}
		undef $txt; # free memory
	}
}

sub index_list_id ($$$) {
	my ($self, $doc, $hdr) = @_;
	for my $l ($hdr->header_raw('List-Id')) {
		$l =~ /<([^>]+)>/ or next;
		my $lid = lc $1;
		$doc->add_boolean_term('G' . $lid);
		index_phrase($self, $lid, 1, 'XL'); # probabilistic
	}
}

sub index_ids ($$$$) {
	my ($self, $doc, $hdr, $mids) = @_;
	for my $mid (@$mids) {
		index_phrase($self, $mid, 1, 'XM');

		# because too many Message-IDs are prefixed with
		# "Pine.LNX."...
		if ($mid =~ /\w{12,}/) {
			my @long = ($mid =~ /(\w{3,}+)/g);
			index_phrase($self, join(' ', @long), 1, 'XM');
		}
	}
	$doc->add_boolean_term('Q' . $_) for @$mids;
	index_list_id($self, $doc, $hdr);
}

sub eml2doc ($$$;$) {
	my ($self, $eml, $smsg, $mids) = @_;
	$mids //= mids_for_index($eml);
	my $doc = $X->{Document}->new;
	add_val($doc, PublicInbox::Search::TS(), $smsg->{ts});
	my @ds = gmtime($smsg->{ds});
	my $yyyymmdd = strftime('%Y%m%d', @ds);
	add_val($doc, PublicInbox::Search::YYYYMMDD(), $yyyymmdd);
	my $dt = strftime('%Y%m%d%H%M%S', @ds);
	add_val($doc, PublicInbox::Search::DT(), $dt);
	add_val($doc, PublicInbox::Search::BYTES(), $smsg->{bytes});
	add_val($doc, PublicInbox::Search::UID(), $smsg->{num});
	add_val($doc, PublicInbox::Search::THREADID, $smsg->{tid});

	my $tg = term_generator($self);
	$tg->set_document($doc);
	index_headers($self, $smsg);

	if (defined(my $eidx_key = $smsg->{eidx_key})) {
		$doc->add_boolean_term('O'.$eidx_key) if $eidx_key ne '.';
	}
	msg_iter($eml, \&index_xapian, [ $self, $doc ]);
	index_ids($self, $doc, $eml, $mids);

	# by default, we maintain compatibility with v1.5.0 and earlier
	# by writing to docdata.glass, users who never exect to downgrade can
	# use --skip-docdata
	if (!$self->{-skip_docdata}) {
		# WWW doesn't need {to} or {cc}, only NNTP
		$smsg->{to} = $smsg->{cc} = '';
		$smsg->parse_references($eml, $mids);
		my $data = $smsg->to_doc_data;
		$doc->set_data($data);
	}

	if (my $altid = $self->{-altid}) {
		foreach my $alt (@$altid) {
			my $pfx = $alt->{xprefix};
			foreach my $mid (@$mids) {
				my $id = $alt->mid2alt($mid);
				next unless defined $id;
				$doc->add_boolean_term($pfx . $id);
			}
		}
	}
	$doc;
}

sub add_xapian ($$$$) {
	my ($self, $eml, $smsg, $mids) = @_;
	begin_txn_lazy($self);
	my $merge_vmd = delete $smsg->{-merge_vmd};
	my $doc = eml2doc($self, $eml, $smsg, $mids);
	if (my $old = $merge_vmd ? _get_doc($self, $smsg->{num}) : undef) {
		my @x = @VMD_MAP;
		while (my ($field, $pfx) = splice(@x, 0, 2)) {
			for my $term (xap_terms($pfx, $old)) {
				$doc->add_boolean_term($pfx.$term);
			}
		}
	}
	$self->{xdb}->replace_document($smsg->{num}, $doc);
}

sub _msgmap_init ($) {
	my ($self) = @_;
	die "BUG: _msgmap_init is only for v1\n" if $self->{ibx}->version != 1;
	$self->{mm} //= do {
		require PublicInbox::Msgmap;
		PublicInbox::Msgmap->new_file($self->{ibx}, 1);
	};
}

sub add_message {
	# mime = PublicInbox::Eml or Email::MIME object
	my ($self, $mime, $smsg, $sync) = @_;
	begin_txn_lazy($self);
	my $mids = mids_for_index($mime);
	$smsg //= bless { blob => '' }, 'PublicInbox::Smsg'; # test-only compat
	$smsg->{mid} //= $mids->[0]; # v1 compatibility
	$smsg->{num} //= do { # v1
		_msgmap_init($self);
		index_mm($self, $mime, $smsg->{blob}, $sync);
	};

	# v1 and tests only:
	$smsg->populate($mime, $sync);
	$smsg->{bytes} //= length($mime->as_string);

	eval {
		# order matters, overview stores every possible piece of
		# data in doc_data (deflated).  Xapian only stores a subset
		# of the fields which exist in over.sqlite3.  We may stop
		# storing doc_data in Xapian sometime after we get multi-inbox
		# search working.
		if (my $oidx = $self->{oidx}) { # v1 only
			$oidx->add_overview($mime, $smsg);
		}
		if (need_xapian($self)) {
			add_xapian($self, $mime, $smsg, $mids);
		}
	};

	if ($@) {
		warn "failed to index message <".join('> <',@$mids).">: $@\n";
		return undef;
	}
	$smsg->{num};
}

sub _get_doc ($$) {
	my ($self, $docid) = @_;
	my $doc = eval { $self->{xdb}->get_document($docid) };
	$doc // do {
		warn "E: $@\n" if $@;
		warn "E: #$docid missing in Xapian\n";
		undef;
	}
}

sub add_eidx_info {
	my ($self, $docid, $eidx_key, $eml) = @_;
	begin_txn_lazy($self);
	my $doc = _get_doc($self, $docid) or return;
	term_generator($self)->set_document($doc);

	# '.' is special for lei_store
	$doc->add_boolean_term('O'.$eidx_key) if $eidx_key ne '.';

	index_list_id($self, $doc, $eml);
	$self->{xdb}->replace_document($docid, $doc);
}

sub get_terms {
	my ($self, $pfx, $docid) = @_;
	begin_txn_lazy($self);
	xap_terms($pfx, $self->{xdb}, $docid);
}

sub remove_eidx_info {
	my ($self, $docid, $eidx_key, $eml) = @_;
	begin_txn_lazy($self);
	my $doc = _get_doc($self, $docid) or return;
	eval { $doc->remove_term('O'.$eidx_key) };
	warn "W: ->remove_term O$eidx_key: $@\n" if $@;
	for my $l ($eml ? $eml->header_raw('List-Id') : ()) {
		$l =~ /<([^>]+)>/ or next;
		my $lid = lc $1;
		eval { $doc->remove_term('G' . $lid) };
		warn "W: ->remove_term G$lid: $@\n" if $@;

		# nb: we don't remove the XL probabilistic terms
		# since terms may overlap if cross-posted.
		#
		# IOW, a message which has both <foo.example.com>
		# and <bar.example.com> would have overlapping
		# "XLexample" and "XLcom" as terms and which we
		# wouldn't know if they're safe to remove if we just
		# unindex <foo.example.com> while preserving
		# <bar.example.com>.
		#
		# In any case, this entire sub is will likely never
		# be needed and users using the "l:" prefix are probably
		# rarer.
	}
	$self->{xdb}->replace_document($docid, $doc);
}

sub set_vmd {
	my ($self, $docid, $vmd) = @_;
	begin_txn_lazy($self);
	my $doc = _get_doc($self, $docid) or return;
	my ($end, @rm, @add);
	my @x = @VMD_MAP;
	while (my ($field, $pfx) = splice(@x, 0, 2)) {
		my $set = $vmd->{$field} // next;
		my %keep = map { $_ => 1 } @$set;
		my %add = %keep;
		$end //= $doc->termlist_end;
		for (my $cur = $doc->termlist_begin; $cur != $end; $cur++) {
			$cur->skip_to($pfx);
			last if $cur == $end;
			my $v = $cur->get_termname;
			$v =~ s/\A$pfx//s or next;
			$keep{$v} ? delete($add{$v}) : push(@rm, $pfx.$v);
		}
		push(@add, map { $pfx.$_ } keys %add);
	}
	return unless scalar(@rm) || scalar(@add);
	$doc->remove_term($_) for @rm;
	$doc->add_boolean_term($_) for @add;
	$self->{xdb}->replace_document($docid, $doc);
}

sub apply_vmd_mod ($$) {
	my ($doc, $vmd_mod) = @_;
	my $updated = 0;
	my @x = @VMD_MAP;
	while (my ($field, $pfx) = splice(@x, 0, 2)) {
		# field: "L" or "kw"
		for my $val (@{$vmd_mod->{"-$field"} // []}) {
			eval {
				$doc->remove_term($pfx . $val);
				++$updated;
			};
		}
		for my $val (@{$vmd_mod->{"+$field"} // []}) {
			$doc->add_boolean_term($pfx . $val);
			++$updated;
		}
	}
	$updated;
}

sub add_vmd {
	my ($self, $docid, $vmd) = @_;
	begin_txn_lazy($self);
	my $doc = _get_doc($self, $docid) or return;
	my @x = @VMD_MAP;
	my $updated = 0;
	while (my ($field, $pfx) = splice(@x, 0, 2)) {
		my $add = $vmd->{$field} // next;
		$doc->add_boolean_term($pfx . $_) for @$add;
		$updated += scalar(@$add);
	}
	$updated += apply_vmd_mod($doc, $vmd);
	$self->{xdb}->replace_document($docid, $doc) if $updated;
}

sub remove_vmd {
	my ($self, $docid, $vmd) = @_;
	begin_txn_lazy($self);
	my $doc = _get_doc($self, $docid) or return;
	my $replace;
	my @x = @VMD_MAP;
	while (my ($field, $pfx) = splice(@x, 0, 2)) {
		my $rm = $vmd->{$field} // next;
		for (@$rm) {
			eval {
				$doc->remove_term($pfx . $_);
				$replace = 1;
			};
		}
	}
	$self->{xdb}->replace_document($docid, $doc) if $replace;
}

sub update_vmd {
	my ($self, $docid, $vmd_mod) = @_;
	begin_txn_lazy($self);
	my $doc = _get_doc($self, $docid) or return;
	my $updated = apply_vmd_mod($doc, $vmd_mod);
	$self->{xdb}->replace_document($docid, $doc) if $updated;
	$updated;
}

sub xdb_remove {
	my ($self, @docids) = @_;
	begin_txn_lazy($self);
	my $xdb = $self->{xdb} // die 'BUG: missing {xdb}';
	for my $docid (@docids) {
		eval { $xdb->delete_document($docid) };
		warn "E: #$docid not in in Xapian? $@\n" if $@;
	}
}

sub xdb_remove_quiet {
	my ($self, $docid) = @_;
	begin_txn_lazy($self);
	my $xdb = $self->{xdb} // die 'BUG: missing {xdb}';
	eval { $xdb->delete_document($docid) };
	++$self->{-quiet_rm} unless $@;
}

sub nr_quiet_rm { delete($_[0]->{-quiet_rm}) // 0 }

sub index_git_blob_id {
	my ($doc, $pfx, $objid) = @_;

	my $len = length($objid);
	for (my $len = length($objid); $len >= 7; ) {
		$doc->add_term($pfx.$objid);
		$objid = substr($objid, 0, --$len);
	}
}

# v1 only
sub unindex_eml {
	my ($self, $oid, $eml) = @_;
	my $mids = mids($eml);
	my $nr = 0;
	my %tmp;
	for my $mid (@$mids) {
		my @removed = $self->{oidx}->remove_oid($oid, $mid);
		$nr += scalar @removed;
		$tmp{$_}++ for @removed;
	}
	if (!$nr) {
		my $m = join('> <', @$mids);
		warn "W: <$m> missing for removal from overview\n";
	}
	while (my ($num, $nr) = each %tmp) {
		warn "BUG: $num appears >1 times ($nr) for $oid\n" if $nr != 1;
	}
	if ($nr) {
		$self->{mm}->num_delete($_) for (keys %tmp);
	} else { # just in case msgmap and over.sqlite3 become desynched:
		$self->{mm}->mid_delete($mids->[0]);
	}
	xdb_remove($self, keys %tmp) if need_xapian($self);
}

sub index_mm {
	my ($self, $mime, $oid, $sync) = @_;
	my $mids = mids($mime);
	my $mm = $self->{mm};
	if ($sync->{reindex}) {
		my $oidx = $self->{oidx};
		for my $mid (@$mids) {
			my ($num, undef) = $oidx->num_mid0_for_oid($oid, $mid);
			return $num if defined $num;
		}
		$mm->num_for($mids->[0]) // $mm->mid_insert($mids->[0]);
	} else {
		# fallback to num_for since filters like RubyLang set the number
		$mm->mid_insert($mids->[0]) // $mm->num_for($mids->[0]);
	}
}

sub is_bad_blob ($$$$) {
	my ($oid, $type, $size, $expect_oid) = @_;
	if ($type ne 'blob') {
		carp "W: $expect_oid is not a blob (type=$type)";
		return 1;
	}
	croak "BUG: $oid != $expect_oid" if $oid ne $expect_oid;
	$size == 0 ? 1 : 0; # size == 0 means purged
}

sub index_both { # git->cat_async callback
	my ($bref, $oid, $type, $size, $sync) = @_;
	return if is_bad_blob($oid, $type, $size, $sync->{oid});
	my ($nr, $max) = @$sync{qw(nr max)};
	++$$nr;
	$$max -= $size;
	my $smsg = bless { blob => $oid }, 'PublicInbox::Smsg';
	$smsg->set_bytes($$bref, $size);
	my $self = $sync->{sidx};
	local $self->{current_info} = "$self->{current_info}: $oid";
	my $eml = PublicInbox::Eml->new($bref);
	$smsg->{num} = index_mm($self, $eml, $oid, $sync) or
		die "E: could not generate NNTP article number for $oid";
	add_message($self, $eml, $smsg, $sync);
	++$self->{nidx};
	my $cur_cmt = $sync->{cur_cmt} // die 'BUG: {cur_cmt} missing';
	${$sync->{latest_cmt}} = $cur_cmt;
}

sub unindex_both { # git->cat_async callback
	my ($bref, $oid, $type, $size, $sync) = @_;
	return if is_bad_blob($oid, $type, $size, $sync->{oid});
	my $self = $sync->{sidx};
	local $self->{current_info} = "$self->{current_info}: $oid";
	unindex_eml($self, $oid, PublicInbox::Eml->new($bref));
	# may be undef if leftover
	if (defined(my $cur_cmt = $sync->{cur_cmt})) {
		${$sync->{latest_cmt}} = $cur_cmt;
	}
	++$self->{nidx};
}

sub with_umask {
	my $self = shift;
	($self->{ibx} // $self->{eidx})->with_umask(@_);
}

# called by public-inbox-index
sub index_sync {
	my ($self, $opt) = @_;
	delete $self->{lock_path} if $opt->{-skip_lock};
	$self->with_umask(\&_index_sync, $self, $opt);
	if ($opt->{reindex} && !$opt->{quit} &&
			!grep(defined, @$opt{qw(since until)})) {
		my %again = %$opt;
		delete @again{qw(rethread reindex)};
		index_sync($self, \%again);
		$opt->{quit} = $again{quit}; # propagate to caller
	}
}

sub check_size { # check_async cb for -index --max-size=...
	my ($oid, $type, $size, $arg, $git) = @_;
	(($type // '') eq 'blob') or die "E: bad $oid in $git->{git_dir}";
	if ($size <= $arg->{max_size}) {
		$git->cat_async($oid, $arg->{index_oid}, $arg);
	} else {
		warn "W: skipping $oid ($size > $arg->{max_size})\n";
	}
}

sub v1_checkpoint ($$;$) {
	my ($self, $sync, $stk) = @_;
	$self->{ibx}->git->async_wait_all;

	# $newest may be undef
	my $newest = $stk ? $stk->{latest_cmt} : ${$sync->{latest_cmt}};
	if (defined($newest)) {
		my $cur = $self->{mm}->last_commit;
		if (need_update($self, $sync, $cur, $newest)) {
			$self->{mm}->last_commit($newest);
		}
	}
	${$sync->{max}} = $self->{batch_bytes};

	$self->{mm}->{dbh}->commit;
	eval { $self->{mm}->{dbh}->do('PRAGMA optimize') };
	my $xdb = $self->{xdb};
	if ($newest && $xdb) {
		my $cur = $xdb->get_metadata('last_commit');
		if (need_update($self, $sync, $cur, $newest)) {
			$xdb->set_metadata('last_commit', $newest);
		}
	}
	if ($stk) { # all done if $stk is passed
		# let SearchView know a full --reindex was done so it can
		# generate ->has_threadid-dependent links
		if ($xdb && $sync->{reindex} && !ref($sync->{reindex})) {
			my $n = $xdb->get_metadata('has_threadid');
			$xdb->set_metadata('has_threadid', '1') if $n ne '1';
		}
		$self->{oidx}->rethread_done($sync->{-opt}); # all done
	}
	commit_txn_lazy($self);
	$sync->{ibx}->git->cleanup;
	my $nr = ${$sync->{nr}};
	idx_release($self, $nr);
	# let another process do some work...
	if (my $pr = $sync->{-opt}->{-progress}) {
		$pr->("indexed $nr/$sync->{ntodo}\n") if $nr;
	}
	if (!$stk && !$sync->{quit}) { # more to come
		begin_txn_lazy($self);
		$self->{mm}->{dbh}->begin_work;
	}
}

# only for v1
sub process_stack {
	my ($self, $sync, $stk) = @_;
	my $git = $sync->{ibx}->git;
	my $max = $self->{batch_bytes};
	my $nr = 0;
	$sync->{nr} = \$nr;
	$sync->{max} = \$max;
	$sync->{sidx} = $self;
	$sync->{latest_cmt} = \(my $latest_cmt);

	$self->{mm}->{dbh}->begin_work;
	if (my @leftovers = keys %{delete($sync->{D}) // {}}) {
		warn('W: unindexing '.scalar(@leftovers)." leftovers\n");
		for my $oid (@leftovers) {
			last if $sync->{quit};
			$oid = unpack('H*', $oid);
			$git->cat_async($oid, \&unindex_both, $sync);
		}
	}
	if ($sync->{max_size} = $sync->{-opt}->{max_size}) {
		$sync->{index_oid} = \&index_both;
	}
	while (my ($f, $at, $ct, $oid, $cur_cmt) = $stk->pop_rec) {
		my $arg = { %$sync, cur_cmt => $cur_cmt, oid => $oid };
		last if $sync->{quit};
		if ($f eq 'm') {
			$arg->{autime} = $at;
			$arg->{cotime} = $ct;
			if ($sync->{max_size}) {
				$git->check_async($oid, \&check_size, $arg);
			} else {
				$git->cat_async($oid, \&index_both, $arg);
			}
			v1_checkpoint($self, $sync) if $max <= 0;
		} elsif ($f eq 'd') {
			$git->cat_async($oid, \&unindex_both, $arg);
		}
	}
	v1_checkpoint($self, $sync, $sync->{quit} ? undef : $stk);
}

sub log2stack ($$$) {
	my ($sync, $git, $range) = @_;
	my $D = $sync->{D}; # OID_BIN => NR (if reindexing, undef otherwise)
	my ($add, $del);
	if ($sync->{ibx}->version == 1) {
		my $path = $hex.'{2}/'.$hex.'{38}';
		$add = qr!\A:000000 100644 \S+ ($OID) A\t$path$!;
		$del = qr!\A:100644 000000 ($OID) \S+ D\t$path$!;
	} else {
		$del = qr!\A:\d{6} 100644 $OID ($OID) [AM]\td$!;
		$add = qr!\A:\d{6} 100644 $OID ($OID) [AM]\tm$!;
	}

	# Count the new files so they can be added newest to oldest
	# and still have numbers increasing from oldest to newest
	my @cmd = qw(log --raw -r --pretty=tformat:%at-%ct-%H
			--no-notes --no-color --no-renames --no-abbrev);
	for my $k (qw(since until)) {
		my $v = $sync->{-opt}->{$k} // next;
		next if !$sync->{-opt}->{reindex};
		push @cmd, "--$k=$v";
	}
	my $fh = $git->popen(@cmd, $range);
	my ($at, $ct, $stk, $cmt);
	while (<$fh>) {
		return if $sync->{quit};
		if (/\A([0-9]+)-([0-9]+)-($OID)$/o) {
			($at, $ct, $cmt) = ($1 + 0, $2 + 0, $3);
			$stk //= PublicInbox::IdxStack->new($cmt);
		} elsif (/$del/) {
			my $oid = $1;
			if ($D) { # reindex case
				$D->{pack('H*', $oid)}++;
			} else { # non-reindex case:
				$stk->push_rec('d', $at, $ct, $oid, $cmt);
			}
		} elsif (/$add/) {
			my $oid = $1;
			if ($D) {
				my $oid_bin = pack('H*', $oid);
				my $nr = --$D->{$oid_bin};
				delete($D->{$oid_bin}) if $nr <= 0;
				# nr < 0 (-1) means it never existed
				next if $nr >= 0;
			}
			$stk->push_rec('m', $at, $ct, $oid, $cmt);
		}
	}
	close $fh or die "git log failed: \$?=$?";
	$stk //= PublicInbox::IdxStack->new;
	$stk->read_prepare;
}

sub prepare_stack ($$) {
	my ($sync, $range) = @_;
	my $git = $sync->{ibx}->git;

	if (index($range, '..') < 0) {
		# don't show annoying git errors to users who run -index
		# on empty inboxes
		$git->qx(qw(rev-parse -q --verify), "$range^0");
		return PublicInbox::IdxStack->new->read_prepare if $?;
	}
	$sync->{D} = $sync->{reindex} ? {} : undef; # OID_BIN => NR
	log2stack($sync, $git, $range);
}

# --is-ancestor requires git 1.8.0+
sub is_ancestor ($$$) {
	my ($git, $cur, $tip) = @_;
	return 0 unless $git->check($cur);
	my $cmd = [ 'git', "--git-dir=$git->{git_dir}",
		qw(merge-base --is-ancestor), $cur, $tip ];
	my $pid = spawn($cmd);
	waitpid($pid, 0) == $pid or die join(' ', @$cmd) .' did not finish';
	$? == 0;
}

sub need_update ($$$$) {
	my ($self, $sync, $cur, $new) = @_;
	my $git = $self->{ibx}->git;
	$cur //= ''; # XS Search::Xapian ->get_metadata doesn't give undef

	# don't rewind if --{since,until,before,after} are in use
	return if $cur ne '' &&
		grep(defined, @{$sync->{-opt}}{qw(since until)}) &&
		is_ancestor($git, $new, $cur);

	return 1 if $cur ne '' && !is_ancestor($git, $cur, $new);
	my $range = $cur eq '' ? $new : "$cur..$new";
	chomp(my $n = $git->qx(qw(rev-list --count), $range));
	($n eq '' || $n > 0);
}

# The last git commit we indexed with Xapian or SQLite (msgmap)
# This needs to account for cases where Xapian or SQLite is
# out-of-date with respect to the other.
sub _last_x_commit {
	my ($self, $mm) = @_;
	my $lm = $mm->last_commit || '';
	my $lx = '';
	if (need_xapian($self)) {
		$lx = $self->{xdb}->get_metadata('last_commit') || '';
	} else {
		$lx = $lm;
	}
	# Use last_commit from msgmap if it is older or unset
	if (!$lm || ($lx && $lm && is_ancestor($self->{ibx}->git, $lm, $lx))) {
		$lx = $lm;
	}
	$lx;
}

sub reindex_from ($$) {
	my ($reindex, $last_commit) = @_;
	return $last_commit unless $reindex;
	ref($reindex) eq 'HASH' ? $reindex->{from} : '';
}

sub quit_cb ($) {
	my ($sync) = @_;
	sub {
		# we set {-opt}->{quit} too, so ->index_sync callers
		# can abort multi-inbox loops this way
		$sync->{quit} = $sync->{-opt}->{quit} = 1;
		warn "gracefully quitting\n";
	}
}

# indexes all unindexed messages (v1 only)
sub _index_sync {
	my ($self, $opt) = @_;
	my $tip = $opt->{ref} || 'HEAD';
	my $ibx = $self->{ibx};
	local $self->{current_info} = "$ibx->{inboxdir}";
	$self->{batch_bytes} = $opt->{batch_size} // $BATCH_BYTES;
	$ibx->git->batch_prepare;
	my $pr = $opt->{-progress};
	my $sync = { reindex => $opt->{reindex}, -opt => $opt, ibx => $ibx };
	my $quit = quit_cb($sync);
	local $SIG{QUIT} = $quit;
	local $SIG{INT} = $quit;
	local $SIG{TERM} = $quit;
	my $xdb = $self->begin_txn_lazy;
	$self->{oidx}->rethread_prepare($opt);
	my $mm = _msgmap_init($self);
	if ($sync->{reindex}) {
		my $last = $mm->last_commit;
		if ($last) {
			$tip = $last;
		} else {
			# somebody just blindly added --reindex when indexing
			# for the first time, allow it:
			undef $sync->{reindex};
		}
	}
	my $last_commit = _last_x_commit($self, $mm);
	my $lx = reindex_from($sync->{reindex}, $last_commit);
	my $range = $lx eq '' ? $tip : "$lx..$tip";
	$pr->("counting changes\n\t$range ... ") if $pr;
	my $stk = prepare_stack($sync, $range);
	$sync->{ntodo} = $stk ? $stk->num_records : 0;
	$pr->("$sync->{ntodo}\n") if $pr; # continue previous line
	process_stack($self, $sync, $stk) if !$sync->{quit};
}

sub DESTROY {
	# order matters for unlocking
	$_[0]->{xdb} = undef;
	$_[0]->{lockfh} = undef;
}

sub _begin_txn {
	my ($self) = @_;
	my $xdb = $self->{xdb} || idx_acquire($self);
	$self->{oidx}->begin_lazy if $self->{oidx};
	$xdb->begin_transaction if $xdb;
	$self->{txn} = 1;
	$xdb;
}

sub begin_txn_lazy {
	my ($self) = @_;
	$self->with_umask(\&_begin_txn, $self) if !$self->{txn};
}

# store 'indexlevel=medium' in v2 shard=0 and v1 (only one shard)
# This metadata is read by Admin::detect_indexlevel:
sub set_metadata_once {
	my ($self) = @_;

	return if $self->{shard}; # only continue if undef or 0, not >0
	my $xdb = $self->{xdb};

	if (delete($self->{-set_has_threadid_once})) {
		$xdb->set_metadata('has_threadid', '1');
	}
	if (delete($self->{-set_indexlevel_once})) {
		my $level = $xdb->get_metadata('indexlevel');
		if (!$level || $level ne 'medium') {
			$xdb->set_metadata('indexlevel', 'medium');
		}
	}
	if (delete($self->{-set_skip_docdata_once})) {
		$xdb->get_metadata('skip_docdata') or
			$xdb->set_metadata('skip_docdata', '1');
	}
}

sub _commit_txn {
	my ($self) = @_;
	if (my $eidx = $self->{eidx}) {
		$eidx->git->async_wait_all;
		$eidx->{transact_bytes} = 0;
	}
	if (my $xdb = $self->{xdb}) {
		set_metadata_once($self);
		$xdb->commit_transaction;
	}
	$self->{oidx}->commit_lazy if $self->{oidx};
}

sub commit_txn_lazy {
	my ($self) = @_;
	delete($self->{txn}) and
		$self->with_umask(\&_commit_txn, $self);
}

sub eidx_shard_new {
	my ($class, $eidx, $shard) = @_;
	my $self = bless {
		eidx => $eidx,
		xpfx => $eidx->{xpfx},
		indexlevel => $eidx->{indexlevel},
		-skip_docdata => 1,
		shard => $shard,
		creat => 1,
	}, $class;
	$self->{-set_indexlevel_once} = 1 if $self->{indexlevel} eq 'medium';
	$self;
}

1;
