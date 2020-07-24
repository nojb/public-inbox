# Copyright (C) 2015-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Indexes mail with Xapian and our (SQLite-based) ::Msgmap for use
# with the web and NNTP interfaces.  This index maintains thread
# relationships for use by PublicInbox::SearchThread.
# This writes to the search index.
package PublicInbox::SearchIdx;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Search PublicInbox::Lock);
use PublicInbox::Eml;
use PublicInbox::InboxWritable;
use PublicInbox::MID qw(mid_mime mids_for_index mids);
use PublicInbox::MsgIter;
use PublicInbox::IdxStack;
use Carp qw(croak);
use POSIX qw(strftime);
use PublicInbox::OverIdx;
use PublicInbox::Spawn qw(spawn);
use PublicInbox::Git qw(git_unquote);
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);
my $X = \%PublicInbox::Search::X;
my ($DB_CREATE_OR_OPEN, $DB_OPEN);
our $BATCH_BYTES = defined($ENV{XAPIAN_FLUSH_THRESHOLD}) ?
			0x7fffffff : 1_000_000;
use constant DEBUG => !!$ENV{DEBUG};

my $xapianlevels = qr/\A(?:full|medium)\z/;
my $hex = '[a-f0-9]';
my $OID = $hex .'{40,}';
my $addmsg = qr!^:000000 100644 \S+ ($OID) A\t${hex}{2}/${hex}{38}$!;
my $delmsg = qr!^:100644 000000 ($OID) \S+ D\t${hex}{2}/${hex}{38}$!;

sub new {
	my ($class, $ibx, $creat, $shard) = @_;
	ref $ibx or die "BUG: expected PublicInbox::Inbox object: $ibx";
	my $levels = qr/\A(?:full|medium|basic)\z/;
	my $inboxdir = $ibx->{inboxdir};
	my $version = $ibx->version;
	my $indexlevel = 'full';
	my $altid = $ibx->{altid};
	if ($altid) {
		require PublicInbox::AltId;
		$altid = [ map { PublicInbox::AltId->new($ibx, $_); } @$altid ];
	}
	if ($ibx->{indexlevel}) {
		if ($ibx->{indexlevel} =~ $levels) {
			$indexlevel = $ibx->{indexlevel};
		} else {
			die("Invalid indexlevel $ibx->{indexlevel}\n");
		}
	}
	$ibx = PublicInbox::InboxWritable->new($ibx);
	my $self = bless {
		ibx => $ibx,
		xpfx => $inboxdir, # for xpfx_init
		-altid => $altid,
		ibx_ver => $version,
		indexlevel => $indexlevel,
	}, $class;
	$self->xpfx_init;
	$self->{-set_indexlevel_once} = 1 if $indexlevel eq 'medium';
	$ibx->umask_prepare;
	if ($version == 1) {
		$self->{lock_path} = "$inboxdir/ssoma.lock";
		my $dir = $self->xdir;
		$self->{over} = PublicInbox::OverIdx->new("$dir/over.sqlite3");
		$self->{index_max_size} = $ibx->{index_max_size};
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
		my $xdb = delete $self->{xdb} or croak 'not acquired';
		$xdb->close;
	}
	$self->lock_release($wake) if $self->{creat};
	undef;
}

sub load_xapian_writable () {
	return 1 if $X->{WritableDatabase};
	PublicInbox::Search::load_xapian() or return;
	my $xap = $PublicInbox::Search::Xap;
	for (qw(Document TermGenerator WritableDatabase)) {
		$X->{$_} = $xap.'::'.$_;
	}
	eval 'require '.$X->{WritableDatabase} or die;
	*sortable_serialise = $xap.'::sortable_serialise';
	$DB_CREATE_OR_OPEN = eval($xap.'::DB_CREATE_OR_OPEN()');
	$DB_OPEN = eval($xap.'::DB_OPEN()');
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
		if (!$is_shard || ($is_shard && need_xapian($self))) {
			File::Path::mkpath($dir);
		}
	}
	return unless defined $flag;
	my $xdb = eval { ($X->{WritableDatabase})->new($dir, $flag) };
	if ($@) {
		die "Failed opening $dir: ", $@;
	}
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
		$tg->set_stemmer($self->stemmer);
		$tg;
	}
}

sub index_text ($$$$) {
	my ($self, $text, $wdf_inc, $prefix) = @_;
	my $tg = term_generator($self); # man Search::Xapian::TermGenerator

	if ($self->{indexlevel} eq 'full') {
		$tg->index_text($text, $wdf_inc, $prefix);
		$tg->increase_termpos;
	} else {
		$tg->index_text_without_positions($text, $wdf_inc, $prefix);
	}
}

sub index_headers ($$) {
	my ($self, $smsg) = @_;
	my @x = (from => 'A', # Author
		subject => 'S', to => 'XTO', cc => 'XCC');
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
	index_text($self, $text, 1, $pfx);
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
		index_text($self, $fn, 1, 'XFN');
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

sub index_ids ($$$$) {
	my ($self, $doc, $hdr, $mids) = @_;
	for my $mid (@$mids) {
		index_text($self, $mid, 1, 'XM');

		# because too many Message-IDs are prefixed with
		# "Pine.LNX."...
		if ($mid =~ /\w{12,}/) {
			my @long = ($mid =~ /(\w{3,}+)/g);
			index_text($self, join(' ', @long), 1, 'XM');
		}
	}
	$doc->add_boolean_term('Q' . $_) for @$mids;
	for my $l ($hdr->header_raw('List-Id')) {
		$l =~ /<([^>]+)>/ or next;
		my $lid = $1;
		$doc->add_boolean_term('G' . $lid);
		index_text($self, $lid, 1, 'XL'); # probabilistic
	}
}

sub add_xapian ($$$$) {
	my ($self, $mime, $smsg, $mids) = @_;
	my $hdr = $mime->header_obj;
	my $doc = $X->{Document}->new;
	add_val($doc, PublicInbox::Search::TS(), $smsg->{ts});
	my @ds = gmtime($smsg->{ds});
	my $yyyymmdd = strftime('%Y%m%d', @ds);
	add_val($doc, PublicInbox::Search::YYYYMMDD(), $yyyymmdd);
	my $dt = strftime('%Y%m%d%H%M%S', @ds);
	add_val($doc, PublicInbox::Search::DT(), $dt);
	add_val($doc, PublicInbox::Search::BYTES(), $smsg->{bytes});
	add_val($doc, PublicInbox::Search::UID(), $smsg->{num});

	my $tg = term_generator($self);
	$tg->set_document($doc);
	index_headers($self, $smsg);

	msg_iter($mime, \&index_xapian, [ $self, $doc ]);
	index_ids($self, $doc, $hdr, $mids);
	$smsg->{to} = $smsg->{cc} = ''; # WWW doesn't need these, only NNTP
	PublicInbox::OverIdx::parse_references($smsg, $hdr, $mids);
	my $data = $smsg->to_doc_data;
	$doc->set_data($data);
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
	$self->{xdb}->replace_document($smsg->{num}, $doc);
}

sub _msgmap_init ($) {
	my ($self) = @_;
	die "BUG: _msgmap_init is only for v1\n" if $self->{ibx_ver} != 1;
	$self->{mm} //= eval {
		require PublicInbox::Msgmap;
		PublicInbox::Msgmap->new($self->{ibx}->{inboxdir}, 1);
	};
}

sub add_message {
	# mime = PublicInbox::Eml or Email::MIME object
	my ($self, $mime, $smsg, $sync) = @_;
	my $hdr = $mime->header_obj;
	my $mids = mids_for_index($hdr);
	$smsg //= bless { blob => '' }, 'PublicInbox::Smsg'; # test-only compat
	$smsg->{mid} //= $mids->[0]; # v1 compatibility
	$smsg->{num} //= do { # v1
		_msgmap_init($self);
		index_mm($self, $mime, $smsg->{blob}, $sync);
	};

	# v1 and tests only:
	$smsg->populate($hdr, $sync);
	$smsg->{bytes} //= length($mime->as_string);

	eval {
		# order matters, overview stores every possible piece of
		# data in doc_data (deflated).  Xapian only stores a subset
		# of the fields which exist in over.sqlite3.  We may stop
		# storing doc_data in Xapian sometime after we get multi-inbox
		# search working.
		if (my $over = $self->{over}) { # v1 only
			$over->add_overview($mime, $smsg);
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

sub xdb_remove {
	my ($self, $oid, @removed) = @_;
	my $xdb = $self->{xdb} or return;
	for my $num (@removed) {
		my $doc = eval { $xdb->get_document($num) };
		unless ($doc) {
			warn "E: $@\n" if $@;
			warn "E: #$num $oid missing in Xapian\n";
			next;
		}
		my $smsg = bless {}, 'PublicInbox::Smsg';
		$smsg->load_expand($doc);
		my $blob = $smsg->{blob} // '(unset)';
		if ($blob eq $oid) {
			$xdb->delete_document($num);
		} else {
			warn "E: #$num $oid != $blob in Xapian\n";
		}
	}
}

sub remove_by_oid {
	my ($self, $oid, $num) = @_;
	die "BUG: remove_by_oid is v2-only\n" if $self->{over};
	$self->begin_txn_lazy;
	xdb_remove($self, $oid, $num) if need_xapian($self);
}

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
		my @removed = eval { $self->{over}->remove_oid($oid, $mid) };
		if ($@) {
			warn "E: failed to remove <$mid> from overview: $@\n";
		} else {
			$nr += scalar @removed;
			$tmp{$_}++ for @removed;
		}
	}
	if (!$nr) {
		$mids = join('> <', @$mids);
		warn "W: <$mids> missing for removal from overview\n";
	}
	while (my ($num, $nr) = each %tmp) {
		warn "BUG: $num appears >1 times ($nr) for $oid\n" if $nr != 1;
	}
	xdb_remove($self, $oid, keys %tmp) if need_xapian($self);
}

sub index_mm {
	my ($self, $mime, $oid, $sync) = @_;
	my $mids = mids($mime);
	my $mm = $self->{mm};
	if ($sync->{reindex}) {
		my $over = $self->{over};
		for my $mid (@$mids) {
			my ($num, undef) = $over->num_mid0_for_oid($oid, $mid);
			return $num if defined $num;
		}
		$mm->num_for($mids->[0]) // $mm->mid_insert($mids->[0]);
	} else {
		# fallback to num_for since filters like RubyLang set the number
		$mm->mid_insert($mids->[0]) // $mm->num_for($mids->[0]);
	}
}

sub unindex_mm {
	my ($self, $mime) = @_;
	$self->{mm}->mid_delete(mid_mime($mime));
}

# returns the number of bytes to add if given a non-CRLF arg
sub crlf_adjust ($) {
	if (index($_[0], "\r\n") < 0) {
		# common case is LF-only, every \n needs an \r;
		# so favor a cheap tr// over an expensive m//g
		$_[0] =~ tr/\n/\n/;
	} else { # count number of '\n' w/o '\r', expensive:
		scalar(my @n = ($_[0] =~ m/(?<!\r)\n/g));
	}
}

sub index_both { # git->cat_async callback
	my ($bref, $oid, $type, $size, $sync) = @_;
	my ($nr, $max) = @$sync{qw(nr max)};
	++$$nr;
	$$max -= $size;
	$size += crlf_adjust($$bref);
	my $smsg = bless { bytes => $size, blob => $oid }, 'PublicInbox::Smsg';
	my $self = $sync->{sidx};
	my $eml = PublicInbox::Eml->new($bref);
	$smsg->{num} = index_mm($self, $eml, $oid, $sync) or
		die "E: could not generate NNTP article number for $oid";
	add_message($self, $eml, $smsg, $sync);
}

sub unindex_both { # git->cat_async callback
	my ($bref, $oid, $type, $size, $self) = @_;
	my $eml = PublicInbox::Eml->new($bref);
	unindex_eml($self, $oid, $eml);
	unindex_mm($self, $eml);
}

# called by public-inbox-index
sub index_sync {
	my ($self, $opts) = @_;
	delete $self->{lock_path} if $opts->{-skip_lock};
	$self->{ibx}->with_umask(\&_index_sync, $self, $opts);
	if ($opts->{reindex}) {
		my %again = %$opts;
		delete @again{qw(rethread reindex)};
		index_sync($self, \%again);
	}
}

sub too_big ($$) {
	my ($self, $oid) = @_;
	my $max_size = $self->{index_max_size} or return;
	my (undef, undef, $size) = $self->{ibx}->git->check($oid);
	die "E: bad $oid in $self->{ibx}->{inboxdir}\n" if !defined($size);
	return if $size <= $max_size;
	warn "W: skipping $oid ($size > $max_size)\n";
	1;
}

# only for v1
sub process_stack {
	my ($self, $stk, $sync, $batch_cb) = @_;
	my $git = $self->{ibx}->git;
	my $max = $BATCH_BYTES;
	my $nr = 0;
	$sync->{nr} = \$nr;
	$sync->{max} = \$max;
	$sync->{sidx} = $self;

	if (my @leftovers = keys %{delete($sync->{D}) // {}}) {
		warn('W: unindexing '.scalar(@leftovers)." leftovers\n");
		for my $oid (@leftovers) {
			$oid = unpack('H*', $oid);
			$git->cat_async($oid, \&unindex_both, $self);
		}
	}
	while (my ($f, $at, $ct, $oid) = $stk->pop_rec) {
		if ($f eq 'm') {
			$sync->{autime} = $at;
			$sync->{cotime} = $ct;
			next if too_big($self, $oid);
			$git->cat_async($oid, \&index_both, { %$sync });
			if ($max <= 0) {
				$git->cat_async_wait;
				$max = $BATCH_BYTES;
				$batch_cb->($nr);
			}
		} elsif ($f eq 'd') {
			$git->cat_async($oid, \&unindex_both, $self);
		}
	}
	$git->cat_async_wait;
	$batch_cb->($nr, $stk);
}

sub prepare_stack ($$$) {
	my ($self, $sync, $range) = @_;
	my $git = $self->{ibx}->git;

	if (index($range, '..') < 0) {
		# don't show annoying git errors to users who run -index
		# on empty inboxes
		$git->qx(qw(rev-parse -q --verify), "$range^0");
		return PublicInbox::IdxStack->new->read_prepare if $?;
	}
	my $D = $sync->{D} = $sync->{reindex} ? {} : undef; # OID_BIN => NR

	# Count the new files so they can be added newest to oldest
	# and still have numbers increasing from oldest to newest
	my $fh = $git->popen(qw(log --raw -r --pretty=tformat:%at-%ct-%H
				--no-notes --no-color --no-renames --no-abbrev),
				$range);
	my ($at, $ct, $stk);
	while (<$fh>) {
		if (/\A([0-9]+)-([0-9]+)-($OID)$/o) {
			($at, $ct) = ($1 + 0, $2 + 0);
			$stk //= PublicInbox::IdxStack->new($3);
		} elsif (/$delmsg/) {
			my $oid = $1;
			if ($D) { # reindex case
				$D->{pack('H*', $oid)}++;
			} else { # non-reindex case:
				$stk->push_rec('d', $at, $ct, $oid);
			}
		} elsif (/$addmsg/) {
			my $oid = $1;
			if ($D) {
				my $oid_bin = pack('H*', $oid);
				my $nr = --$D->{$oid_bin};
				delete($D->{$oid_bin}) if $nr <= 0;

				# nr < 0 (-1) means it never existed
				$stk->push_rec('m', $at, $ct, $oid) if $nr < 0;
			} else {
				$stk->push_rec('m', $at, $ct, $oid);
			}
		}
	}
	close $fh or die "git log failed: \$?=$?";
	$stk //= PublicInbox::IdxStack->new;
	$stk->read_prepare;
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

sub need_update ($$$) {
	my ($self, $cur, $new) = @_;
	my $git = $self->{ibx}->git;
	return 1 if $cur && !is_ancestor($git, $cur, $new);
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

# indexes all unindexed messages (v1 only)
sub _index_sync {
	my ($self, $opts) = @_;
	my $tip = $opts->{ref} || 'HEAD';
	my $git = $self->{ibx}->git;
	$git->batch_prepare;
	my $pr = $opts->{-progress};
	my $sync = { reindex => $opts->{reindex} };
	my $xdb = $self->begin_txn_lazy;
	$self->{over}->rethread_prepare($opts);
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
	my $stk = prepare_stack($self, $sync, $range);
	$sync->{ntodo} = $stk ? $stk->num_records : 0;
	$pr->("$sync->{ntodo}\n") if $pr; # continue previous line

	my $dbh = $mm->{dbh};
	my $batch_cb = sub {
		my ($nr, $stk) = @_;
		# latest_cmt may be undef
		my $newest = $stk ? $stk->{latest_cmt} : undef;
		if ($newest) {
			my $cur = $mm->last_commit || '';
			if (need_update($self, $cur, $newest)) {
				$mm->last_commit($newest);
			}
		}
		$dbh->commit;
		if ($newest && need_xapian($self)) {
			my $cur = $xdb->get_metadata('last_commit');
			if (need_update($self, $cur, $newest)) {
				$xdb->set_metadata('last_commit', $newest);
			}
		}

		$self->{over}->rethread_done($opts) if $newest; # all done
		$self->commit_txn_lazy;
		$git->cleanup;
		$xdb = idx_release($self, $nr);
		# let another process do some work...
		$pr->("indexed $nr/$sync->{ntodo}\n") if $pr && $nr;
		if (!$stk) { # more to come
			$xdb = $self->begin_txn_lazy;
			$dbh->begin_work;
		}
	};

	$dbh->begin_work;
	process_stack($self, $stk, $sync, $batch_cb);
}

sub DESTROY {
	# order matters for unlocking
	$_[0]->{xdb} = undef;
	$_[0]->{lockfh} = undef;
}

# remote_* subs are only used by SearchIdxPart
sub remote_commit {
	my ($self) = @_;
	if (my $w = $self->{w}) {
		print $w "commit\n" or die "failed to write commit: $!";
	} else {
		$self->commit_txn_lazy;
	}
}

sub remote_close {
	my ($self) = @_;
	if (my $w = delete $self->{w}) {
		my $pid = delete $self->{pid} or die "no process to wait on\n";
		print $w "close\n" or die "failed to write to pid:$pid: $!\n";
		close $w or die "failed to close pipe for pid:$pid: $!\n";
		waitpid($pid, 0) == $pid or die "remote process did not finish";
		$? == 0 or die ref($self)." pid:$pid exited with: $?";
	} else {
		die "transaction in progress $self\n" if $self->{txn};
		idx_release($self) if $self->{xdb};
	}
}

sub remote_remove {
	my ($self, $oid, $num) = @_;
	if (my $w = $self->{w}) {
		# triggers remove_by_oid in a shard
		print $w "D $oid $num\n" or die "failed to write remove $!";
	} else {
		$self->remove_by_oid($oid, $num);
	}
}

sub _begin_txn {
	my ($self) = @_;
	my $xdb = $self->{xdb} || idx_acquire($self);
	$self->{over}->begin_lazy if $self->{over};
	$xdb->begin_transaction if $xdb;
	$self->{txn} = 1;
	$xdb;
}

sub begin_txn_lazy {
	my ($self) = @_;
	$self->{ibx}->with_umask(\&_begin_txn, $self) if !$self->{txn};
}

# store 'indexlevel=medium' in v2 shard=0 and v1 (only one shard)
# This metadata is read by Admin::detect_indexlevel:
sub set_indexlevel {
	my ($self) = @_;

	if (!$self->{shard} && # undef or 0, not >0
			delete($self->{-set_indexlevel_once})) {
		my $xdb = $self->{xdb};
		my $level = $xdb->get_metadata('indexlevel');
		if (!$level || $level ne 'medium') {
			$xdb->set_metadata('indexlevel', 'medium');
		}
	}
}

sub _commit_txn {
	my ($self) = @_;
	if (my $xdb = $self->{xdb}) {
		set_indexlevel($self);
		$xdb->commit_transaction;
	}
	$self->{over}->commit_lazy if $self->{over};
}

sub commit_txn_lazy {
	my ($self) = @_;
	delete($self->{txn}) and
		$self->{ibx}->with_umask(\&_commit_txn, $self);
}

sub worker_done {
	my ($self) = @_;
	if (need_xapian($self)) {
		die "$$ $0 xdb not released\n" if $self->{xdb};
	}
	die "$$ $0 still in transaction\n" if $self->{txn};
}

1;
