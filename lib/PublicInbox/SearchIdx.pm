# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Indexes mail with Xapian and our (SQLite-based) ::Msgmap for use
# with the web and NNTP interfaces.  This index maintains thread
# relationships for use by PublicInbox::SearchThread.
# This writes to the search index.
package PublicInbox::SearchIdx;
use strict;
use warnings;
use base qw(PublicInbox::Search PublicInbox::Lock);
use PublicInbox::MIME;
use PublicInbox::InboxWritable;
use PublicInbox::MID qw/mid_clean id_compress mid_mime mids references/;
use PublicInbox::MsgIter;
use Carp qw(croak);
use POSIX qw(strftime);
require PublicInbox::Git;

use constant {
	BATCH_BYTES => 1_000_000,
	DEBUG => !!$ENV{DEBUG},
};

my %GIT_ESC = (
	a => "\a",
	b => "\b",
	f => "\f",
	n => "\n",
	r => "\r",
	t => "\t",
	v => "\013",
);

sub git_unquote ($) {
	my ($s) = @_;
	return $s unless ($s =~ /\A"(.*)"\z/);
	$s = $1;
	$s =~ s/\\([abfnrtv])/$GIT_ESC{$1}/g;
	$s =~ s/\\([0-7]{1,3})/chr(oct($1))/ge;
	$s;
}

sub new {
	my ($class, $ibx, $creat, $part) = @_;
	my $mainrepo = $ibx; # for "public-inbox-index" w/o entry in config
	my $git_dir = $mainrepo;
	my ($altid, $git);
	my $version = 1;
	if (ref $ibx) {
		$mainrepo = $ibx->{mainrepo};
		$altid = $ibx->{altid};
		$version = $ibx->{version} || 1;
		if ($altid) {
			require PublicInbox::AltId;
			$altid = [ map {
				PublicInbox::AltId->new($ibx, $_);
			} @$altid ];
		}
	} else { # v1
		$ibx = { mainrepo => $git_dir, version => 1 };
	}
	$ibx = PublicInbox::InboxWritable->new($ibx);
	require Search::Xapian::WritableDatabase;
	my $self = bless {
		mainrepo => $mainrepo,
		-inbox => $ibx,
		git => $ibx->git,
		-altid => $altid,
		version => $version,
	}, $class;
	$ibx->umask_prepare;
	if ($version == 1) {
		$self->{lock_path} = "$mainrepo/ssoma.lock";
	} elsif ($version == 2) {
		defined $part or die "partition is required for v2\n";
		# partition is a number or "all"
		$self->{partition} = $part;
		$self->{lock_path} = undef;
		$self->{msgmap_path} = "$mainrepo/msgmap.sqlite3";
	} else {
		die "unsupported inbox version=$version\n";
	}
	$self->{creat} = ($creat || 0) == 1;
	$self;
}

sub _xdb_release {
	my ($self) = @_;
	my $xdb = delete $self->{xdb} or croak 'not acquired';
	$xdb->close;
	$self->lock_release if $self->{creat};
	undef;
}

sub _xdb_acquire {
	my ($self) = @_;
	croak 'already acquired' if $self->{xdb};
	my $dir = $self->xdir;
	my $flag = Search::Xapian::DB_OPEN;
	if ($self->{creat}) {
		require File::Path;
		$self->lock_acquire;
		File::Path::mkpath($dir);
		$flag = Search::Xapian::DB_CREATE_OR_OPEN;
	}
	$self->{xdb} = Search::Xapian::WritableDatabase->new($dir, $flag);
}

sub add_val ($$$) {
	my ($doc, $col, $num) = @_;
	$num = Search::Xapian::sortable_serialise($num);
	$doc->add_value($col, $num);
}

sub add_values ($$) {
	my ($doc, $values) = @_;

	my $ts = $values->[PublicInbox::Search::TS];
	add_val($doc, PublicInbox::Search::TS, $ts);

	my $num = $values->[PublicInbox::Search::NUM];
	defined($num) and add_val($doc, PublicInbox::Search::NUM, $num);

	my $bytes = $values->[PublicInbox::Search::BYTES];
	defined($bytes) and add_val($doc, PublicInbox::Search::BYTES, $bytes);

	my $lines = $values->[PublicInbox::Search::LINES];
	add_val($doc, PublicInbox::Search::LINES, $lines);

	my $ds = $values->[PublicInbox::Search::DS];
	add_val($doc, PublicInbox::Search::DS, $ds);
	my $yyyymmdd = strftime('%Y%m%d', gmtime($ds));
	add_val($doc, PublicInbox::Search::YYYYMMDD, $yyyymmdd);
}

sub index_users ($$) {
	my ($tg, $smsg) = @_;

	my $from = $smsg->from;
	my $to = $smsg->to;
	my $cc = $smsg->cc;

	$tg->index_text($from, 1, 'A'); # A - author
	$tg->increase_termpos;
	$tg->index_text($to, 1, 'XTO') if $to ne '';
	$tg->increase_termpos;
	$tg->index_text($cc, 1, 'XCC') if $cc ne '';
	$tg->increase_termpos;
}

sub index_diff_inc ($$$$) {
	my ($tg, $text, $pfx, $xnq) = @_;
	if (@$xnq) {
		$tg->index_text(join("\n", @$xnq), 1, 'XNQ');
		$tg->increase_termpos;
		@$xnq = ();
	}
	$tg->index_text($text, 1, $pfx);
	$tg->increase_termpos;
}

sub index_old_diff_fn {
	my ($tg, $seen, $fa, $fb, $xnq) = @_;

	# no renames or space support for traditional diffs,
	# find the number of leading common paths to strip:
	my @fa = split('/', $fa);
	my @fb = split('/', $fb);
	while (scalar(@fa) && scalar(@fb)) {
		$fa = join('/', @fa);
		$fb = join('/', @fb);
		if ($fa eq $fb) {
			unless ($seen->{$fa}++) {
				index_diff_inc($tg, $fa, 'XDFN', $xnq);
			}
			return 1;
		}
		shift @fa;
		shift @fb;
	}
	0;
}

sub index_diff ($$$) {
	my ($tg, $lines, $doc) = @_;
	my %seen;
	my $in_diff;
	my @xnq;
	my $xnq = \@xnq;
	foreach (@$lines) {
		if ($in_diff && s/^ //) { # diff context
			index_diff_inc($tg, $_, 'XDFCTX', $xnq);
		} elsif (/^-- $/) { # email signature begins
			$in_diff = undef;
		} elsif (m!^diff --git ("?a/.+) ("?b/.+)\z!) {
			my ($fa, $fb) = ($1, $2);
			my $fn = (split('/', git_unquote($fa), 2))[1];
			$seen{$fn}++ or index_diff_inc($tg, $fn, 'XDFN', $xnq);
			$fn = (split('/', git_unquote($fb), 2))[1];
			$seen{$fn}++ or index_diff_inc($tg, $fn, 'XDFN', $xnq);
			$in_diff = 1;
		# traditional diff:
		} elsif (m/^diff -(.+) (\S+) (\S+)$/) {
			my ($opt, $fa, $fb) = ($1, $2, $3);
			push @xnq, $_;
			# only support unified:
			next unless $opt =~ /[uU]/;
			$in_diff = index_old_diff_fn($tg, \%seen, $fa, $fb,
							$xnq);
		} elsif (m!^--- ("?a/.+)!) {
			my $fn = (split('/', git_unquote($1), 2))[1];
			$seen{$fn}++ or index_diff_inc($tg, $fn, 'XDFN', $xnq);
			$in_diff = 1;
		} elsif (m!^\+\+\+ ("?b/.+)!)  {
			my $fn = (split('/', git_unquote($1), 2))[1];
			$seen{$fn}++ or index_diff_inc($tg, $fn, 'XDFN', $xnq);
			$in_diff = 1;
		} elsif (/^--- (\S+)/) {
			$in_diff = $1;
			push @xnq, $_;
		} elsif (defined $in_diff && /^\+\+\+ (\S+)/) {
			$in_diff = index_old_diff_fn($tg, \%seen, $in_diff, $1,
							$xnq);
		} elsif ($in_diff && s/^\+//) { # diff added
			index_diff_inc($tg, $_, 'XDFB', $xnq);
		} elsif ($in_diff && s/^-//) { # diff removed
			index_diff_inc($tg, $_, 'XDFA', $xnq);
		} elsif (m!^index ([a-f0-9]+)\.\.([a-f0-9]+)!) {
			my ($ba, $bb) = ($1, $2);
			index_git_blob_id($doc, 'XDFPRE', $ba);
			index_git_blob_id($doc, 'XDFPOST', $bb);
			$in_diff = 1;
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*$/) {
			# traditional diff w/o -p
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*(\S+.*)$/) {
			# hunk header context
			index_diff_inc($tg, $1, 'XDFHH', $xnq);
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
			$in_diff = undef;
		} else {
			push @xnq, $_;
			warn "non-diff line: $_\n" if DEBUG && $_ ne '';
			$in_diff = undef;
		}
	}

	$tg->index_text(join("\n", @xnq), 1, 'XNQ');
	$tg->increase_termpos;
}

sub index_body ($$$) {
	my ($tg, $lines, $doc) = @_;
	my $txt = join("\n", @$lines);
	if ($doc) {
		# does it look like a diff?
		if ($txt =~ /^(?:diff|---|\+\+\+) /ms) {
			$txt = undef;
			index_diff($tg, $lines, $doc);
		} else {
			$tg->index_text($txt, 1, 'XNQ');
		}
	} else {
		$tg->index_text($txt, 0, 'XQUOT');
	}
	$tg->increase_termpos;
	@$lines = ();
}

sub add_message {
	# mime = Email::MIME object
	my ($self, $mime, $bytes, $num, $oid, $mid0) = @_;
	my $doc_id;
	my $mids = mids($mime->header_obj);
	my $skel = $self->{skeleton};

	eval {
		my $smsg = PublicInbox::SearchMsg->new($mime);
		my $doc = $smsg->{doc};
		my $subj = $smsg->subject;
		my $xpath;
		if ($subj ne '') {
			$xpath = $self->subject_path($subj);
			$xpath = id_compress($xpath);
		}

		my $lines = $mime->body_raw =~ tr!\n!\n!;
		my @values = ($smsg->ds, $num, $bytes, $lines, $smsg->ts);
		add_values($doc, \@values);

		my $tg = $self->term_generator;

		$tg->set_document($doc);
		$tg->index_text($subj, 1, 'S') if $subj;
		$tg->increase_termpos;

		index_users($tg, $smsg);

		msg_iter($mime, sub {
			my ($part, $depth, @idx) = @{$_[0]};
			my $ct = $part->content_type || 'text/plain';
			my $fn = $part->filename;
			if (defined $fn && $fn ne '') {
				$tg->index_text($fn, 1, 'XFN');
			}

			return if $ct =~ m!\btext/x?html\b!i;

			my $s = eval { $part->body_str };
			if ($@) {
				if ($ct =~ m!\btext/plain\b!i) {
					# Try to assume UTF-8 because Alpine
					# seems to do wacky things and set
					# charset=X-UNKNOWN
					$part->charset_set('UTF-8');
					$s = eval { $part->body_str };
					$s = $part->body if $@;
				}
			}
			defined $s or return;

			my (@orig, @quot);
			my $body = $part->body;
			my @lines = split(/\n/, $body);
			while (defined(my $l = shift @lines)) {
				if ($l =~ /^>/) {
					index_body($tg, \@orig, $doc) if @orig;
					push @quot, $l;
				} else {
					index_body($tg, \@quot, 0) if @quot;
					push @orig, $l;
				}
			}
			index_body($tg, \@quot, 0) if @quot;
			index_body($tg, \@orig, $doc) if @orig;
		});

		# populates smsg->references for smsg->to_doc_data
		my $refs = parse_references($smsg);
		$mid0 = $mids->[0] unless defined $mid0; # v1 compatibility
		my $data = $smsg->to_doc_data($oid, $mid0);
		foreach my $mid (@$mids) {
			$tg->index_text($mid, 1, 'XM');
		}
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

		$self->delete_article($num) if defined $num; # for reindexing
		if ($skel) {
			push @values, $mids, $xpath, $data;
			$skel->index_skeleton(\@values);
			$doc->add_boolean_term('Q' . $_) foreach @$mids;
			$doc->add_boolean_term('XNUM' . $num) if defined $num;
			$doc_id = $self->{xdb}->add_document($doc);
		} else {
			$doc_id = link_and_save($self, $doc, $mids, $refs,
						$num, $xpath);
		}
	};

	if ($@) {
		warn "failed to index message <".join('> <',@$mids).">: $@\n";
		return undef;
	}
	$doc_id;
}

# returns begin and end PostingIterator
sub find_doc_ids {
	my ($self, $termval) = @_;
	my $db = $self->{xdb};

	($db->postlist_begin($termval), $db->postlist_end($termval));
}

sub batch_do {
	my ($self, $termval, $cb) = @_;
	my $batch_size = 1000; # don't let @ids grow too large to avoid OOM
	while (1) {
		my ($head, $tail) = $self->find_doc_ids($termval);
		return if $head == $tail;
		my @ids;
		for (; $head != $tail && @ids < $batch_size; $head->inc) {
			push @ids, $head->get_docid;
		}
		$cb->(\@ids);
	}
}

sub remove_message {
	my ($self, $mid) = @_;
	my $db = $self->{xdb};
	my $called;
	$mid = mid_clean($mid);

	eval {
		batch_do($self, 'Q' . $mid, sub {
			my ($ids) = @_;
			$db->delete_document($_) for @$ids;
			$called = 1;
		});
	};
	if ($@) {
		warn "failed to remove message <$mid>: $@\n";
	} elsif (!$called) {
		warn "cannot remove non-existent <$mid>\n";
	}
}

sub delete_article {
	my ($self, $num) = @_;
	my $ndel = 0;
	batch_do($self, 'XNUM' . $num, sub {
		my ($ids) = @_;
		$ndel += scalar @$ids;
		$self->{xdb}->delete_document($_) for @$ids;
	});
}

# MID is a hint in V2
sub remove_by_oid {
	my ($self, $oid, $mid) = @_;
	my $db = $self->{xdb};

	# XXX careful, we cannot use batch_do here since we conditionally
	# delete documents based on other factors, so we cannot call
	# find_doc_ids twice.
	my ($head, $tail) = $self->find_doc_ids('Q' . $mid);
	return if $head == $tail;

	# there is only ONE element in @delete unless we
	# have bugs in our v2writable deduplication check
	my @delete;
	for (; $head != $tail; $head->inc) {
		my $docid = $head->get_docid;
		my $doc = $db->get_document($docid);
		my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->load_expand;
		push(@delete, $docid) if $smsg->{blob} eq $oid;
	}
	$db->delete_document($_) foreach @delete;
	scalar(@delete);
}

sub term_generator { # write-only
	my ($self) = @_;

	my $tg = $self->{term_generator};
	return $tg if $tg;

	$tg = Search::Xapian::TermGenerator->new;
	$tg->set_stemmer($self->stemmer);

	$self->{term_generator} = $tg;
}

# increments last_thread_id counter
# returns a 64-bit integer represented as a decimal string
sub next_thread_id {
	my ($self) = @_;
	my $db = $self->{xdb};
	my $last_thread_id = int($db->get_metadata('last_thread_id') || 0);

	$db->set_metadata('last_thread_id', ++$last_thread_id);

	$last_thread_id;
}

sub parse_references ($) {
	my ($smsg) = @_;
	my $mime = $smsg->{mime};
	my $hdr = $mime->header_obj;
	my $refs = references($hdr);
	return $refs if scalar(@$refs) == 0;

	# prevent circular references via References here:
	my %mids = map { $_ => 1 } @{mids($hdr)};
	my @keep;
	foreach my $ref (@$refs) {
		if (length($ref) > PublicInbox::MID::MAX_MID_SIZE) {
			warn "References: <$ref> too long, ignoring\n";
			next;
		}
		next if $mids{$ref};
		push @keep, $ref;
	}
	$smsg->{references} = '<'.join('> <', @keep).'>' if @keep;
	\@keep;
}

sub link_doc {
	my ($self, $doc, $refs, $old_tid) = @_;
	my $tid;

	if (@$refs) {
		# first ref *should* be the thread root,
		# but we can never trust clients to do the right thing
		my $ref = shift @$refs;
		$tid = resolve_mid_to_tid($self, $ref);
		merge_threads($self, $tid, $old_tid) if defined $old_tid;

		# the rest of the refs should point to this tid:
		foreach $ref (@$refs) {
			my $ptid = resolve_mid_to_tid($self, $ref);
			merge_threads($self, $tid, $ptid);
		}
	} else {
		$tid = defined $old_tid ? $old_tid : $self->next_thread_id;
	}
	$doc->add_boolean_term('G' . $tid);
	$tid;
}

sub link_and_save {
	my ($self, $doc, $mids, $refs, $num, $xpath) = @_;
	my $db = $self->{xdb};
	my $old_tid;
	my $doc_id;
	$doc->add_boolean_term('XNUM' . $num) if defined $num;
	$doc->add_boolean_term('XPATH' . $xpath) if defined $xpath;
	$doc->add_boolean_term('Q' . $_) foreach @$mids;

	$self->{skel} and die "Should not have read-only skel here\n";;
	foreach my $mid (@$mids) {
		my $vivified = 0;
		$self->each_smsg_by_mid($mid, sub {
			my ($cur) = @_;
			my $type = $cur->type;
			my $cur_tid = $cur->thread_id;
			$old_tid = $cur_tid unless defined $old_tid;
			if ($type eq 'mail') {
				# do not break existing mail messages,
				# just merge the threads
				merge_threads($self, $old_tid, $cur_tid);
				return 1;
			}
			if ($type ne 'ghost') {
				die "<$mid> has a bad type: $type\n";
			}
			my $tid = link_doc($self, $doc, $refs, $old_tid);
			$old_tid = $tid unless defined $old_tid;
			$doc_id = $cur->{doc_id};
			$self->{xdb}->replace_document($doc_id, $doc);
			++$vivified;
			1;
		});
		$vivified > 1 and warn
			"BUG: vivified multiple ($vivified) ghosts for $mid\n";
	}
	# not really important, but we return any vivified ghost docid, here:
	return $doc_id if defined $doc_id;
	link_doc($self, $doc, $refs, $old_tid);
	$self->{xdb}->add_document($doc);
}

sub index_git_blob_id {
	my ($doc, $pfx, $objid) = @_;

	my $len = length($objid);
	for (my $len = length($objid); $len >= 7; ) {
		$doc->add_term($pfx.$objid);
		$objid = substr($objid, 0, --$len);
	}
}

sub unindex_blob {
	my ($self, $mime) = @_;
	my $mid = eval { mid_clean(mid_mime($mime)) };
	$self->remove_message($mid) if defined $mid;
}

sub index_mm {
	my ($self, $mime) = @_;
	my $mid = mid_clean(mid_mime($mime));
	my $mm = $self->{mm};
	my $num = $mm->mid_insert($mid);
	return $num if defined $num;

	# fallback to num_for since filters like RubyLang set the number
	$mm->num_for($mid);
}

sub unindex_mm {
	my ($self, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean(mid_mime($mime)));
}

sub index_mm2 {
	my ($self, $mime, $bytes, $blob) = @_;
	my $num = $self->{mm}->num_for(mid_clean(mid_mime($mime)));
	add_message($self, $mime, $bytes, $num, $blob);
}

sub unindex_mm2 {
	my ($self, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean(mid_mime($mime)));
	unindex_blob($self, $mime);
}

sub index_both {
	my ($self, $mime, $bytes, $blob) = @_;
	my $num = index_mm($self, $mime);
	add_message($self, $mime, $bytes, $num, $blob);
}

sub unindex_both {
	my ($self, $mime) = @_;
	unindex_blob($self, $mime);
	unindex_mm($self, $mime);
}

sub do_cat_mail {
	my ($git, $blob, $sizeref) = @_;
	my $mime = eval {
		my $str = $git->cat_file($blob, $sizeref);
		# fixup bugs from import:
		$$str =~ s/\A[\r\n]*From [^\r\n]*\r?\n//s;
		PublicInbox::MIME->new($str);
	};
	$@ ? undef : $mime;
}

sub index_sync {
	my ($self, $opts) = @_;
	$self->{-inbox}->with_umask(sub { $self->_index_sync($opts) })
}

sub batch_adjust ($$$$) {
	my ($max, $bytes, $batch_cb, $latest) = @_;
	$$max -= $bytes;
	if ($$max <= 0) {
		$$max = BATCH_BYTES;
		$batch_cb->($latest, 1);
	}
}

# only for v1
sub rlog {
	my ($self, $log, $add_cb, $del_cb, $batch_cb) = @_;
	my $hex = '[a-f0-9]';
	my $h40 = $hex .'{40}';
	my $addmsg = qr!^:000000 100644 \S+ ($h40) A\t${hex}{2}/${hex}{38}$!;
	my $delmsg = qr!^:100644 000000 ($h40) \S+ D\t${hex}{2}/${hex}{38}$!;
	my $git = $self->{git};
	my $latest;
	my $bytes;
	my $max = BATCH_BYTES;
	local $/ = "\n";
	my $line;
	while (defined($line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $blob = $1;
			my $mime = do_cat_mail($git, $blob, \$bytes) or next;
			batch_adjust(\$max, $bytes, $batch_cb, $latest);
			$add_cb->($self, $mime, $bytes, $blob);
		} elsif ($line =~ /$delmsg/o) {
			my $blob = $1;
			my $mime = do_cat_mail($git, $blob, \$bytes) or next;
			batch_adjust(\$max, $bytes, $batch_cb, $latest);
			$del_cb->($self, $mime);
		} elsif ($line =~ /^commit ($h40)/o) {
			$latest = $1;
		}
	}
	$batch_cb->($latest, 0);
}

sub _msgmap_init {
	my ($self) = @_;
	$self->{mm} ||= eval {
		require PublicInbox::Msgmap;
		my $msgmap_path = $self->{msgmap_path};
		if (defined $msgmap_path) { # v2
			PublicInbox::Msgmap->new_file($msgmap_path, 1);
		} else {
			PublicInbox::Msgmap->new($self->{mainrepo}, 1);
		}
	};
}

sub _git_log {
	my ($self, $range) = @_;
	$self->{git}->popen(qw/log --reverse --no-notes --no-color
				--raw -r --no-abbrev/, $range);
}

# indexes all unindexed messages
sub _index_sync {
	my ($self, $opts) = @_;
	my $tip = $opts->{ref} || 'HEAD';
	my $reindex = $opts->{reindex};
	my ($mkey, $last_commit, $lx, $xlog);
	$self->{git}->batch_prepare;
	my $xdb = _xdb_acquire($self);
	$xdb->begin_transaction;
	do {
		$xlog = undef;
		$mkey = 'last_commit';
		$last_commit = $xdb->get_metadata('last_commit');
		$lx = $last_commit;
		if ($reindex) {
			$lx = '';
			$mkey = undef if $last_commit ne '';
		}
		$xdb->cancel_transaction;
		$xdb = _xdb_release($self);

		# ensure we leak no FDs to "git log"
		my $range = $lx eq '' ? $tip : "$lx..$tip";
		$xlog = _git_log($self, $range);

		$xdb = _xdb_acquire($self);
		$xdb->begin_transaction;
	} while ($xdb->get_metadata('last_commit') ne $last_commit);

	my $mm = _msgmap_init($self);
	my $dbh = $mm->{dbh} if $mm;
	my $mm_only;
	my $cb = sub {
		my ($commit, $more) = @_;
		if ($dbh) {
			$mm->last_commit($commit) if $commit;
			$dbh->commit;
		}
		if (!$mm_only) {
			$xdb->set_metadata($mkey, $commit) if $mkey && $commit;
			$xdb->commit_transaction;
			$xdb = _xdb_release($self);
		}
		# let another process do some work... <
		if ($more) {
			if (!$mm_only) {
				$xdb = _xdb_acquire($self);
				$xdb->begin_transaction;
			}
			$dbh->begin_work if $dbh;
		}
	};

	if ($mm) {
		$dbh->begin_work;
		my $lm = $mm->last_commit || '';
		if ($lm eq $lx) {
			# Common case is the indexes are synced,
			# we only need to run git-log once:
			rlog($self, $xlog, *index_both, *unindex_both, $cb);
		} else {
			# Uncommon case, msgmap and xapian are out-of-sync
			# do not care for performance (but git is fast :>)
			# This happens if we have to reindex Xapian since
			# msgmap is a frozen format and our Xapian format
			# is evolving.
			my $r = $lm eq '' ? $tip : "$lm..$tip";

			# first, ensure msgmap is up-to-date:
			my $mkey_prev = $mkey;
			$mkey = undef; # ignore xapian, for now
			my $mlog = _git_log($self, $r);
			$mm_only = 1;
			rlog($self, $mlog, *index_mm, *unindex_mm, $cb);
			$mm_only = $mlog = undef;

			# now deal with Xapian
			$mkey = $mkey_prev;
			$dbh = undef;
			rlog($self, $xlog, *index_mm2, *unindex_mm2, $cb);
		}
	} else {
		# user didn't install DBD::SQLite and DBI
		rlog($self, $xlog, *add_message, *unindex_blob, $cb);
	}
}

# this will create a ghost as necessary
sub resolve_mid_to_tid {
	my ($self, $mid) = @_;
	my $tid;
	$self->each_smsg_by_mid($mid, sub {
		my ($smsg) = @_;
		my $cur_tid = $smsg->thread_id;
		if (defined $tid) {
			merge_threads($self, $tid, $cur_tid);
		} else {
			$tid = $smsg->thread_id;
		}
		1;
	});
	return $tid if defined $tid;

	$self->create_ghost($mid)->thread_id;
}

sub create_ghost {
	my ($self, $mid) = @_;

	my $tid = $self->next_thread_id;
	my $doc = Search::Xapian::Document->new;
	$doc->add_boolean_term('Q' . $mid);
	$doc->add_boolean_term('G' . $tid);
	$doc->add_boolean_term('T' . 'ghost');

	my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
	$self->{xdb}->add_document($doc);

	$smsg;
}

sub merge_threads {
	my ($self, $winner_tid, $loser_tid) = @_;
	return if $winner_tid == $loser_tid;
	my $db = $self->{xdb};
	batch_do($self, 'G' . $loser_tid, sub {
		my ($ids) = @_;
		foreach my $docid (@$ids) {
			my $doc = $db->get_document($docid);
			$doc->remove_term('G' . $loser_tid);
			$doc->add_boolean_term('G' . $winner_tid);
			$db->replace_document($docid, $doc);
		}
	});
}

sub DESTROY {
	# order matters for unlocking
	$_[0]->{xdb} = undef;
	$_[0]->{lockfh} = undef;
}

# remote_* subs are only used by SearchIdxPart and SearchIdxSkeleton
sub remote_commit {
	my ($self) = @_;
	if (my $w = $self->{w}) {
		print $w "commit\n" or die "failed to write commit: $!";
	} else {
		$self->commit_txn_lazy;
		if (my $skel = $self->{skeleton}) {
			$skel->commit_txn_lazy;
		}
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
		$self->_xdb_release if $self->{xdb};
	}
}

sub remote_remove {
	my ($self, $oid, $mid) = @_;
	if (my $w = $self->{w}) {
		# triggers remove_by_oid in partition or skeleton
		print $w "D $oid $mid\n" or die "failed to write remove $!";
	} else {
		$self->begin_txn_lazy;
		$self->remove_by_oid($oid, $mid);
	}
}

sub begin_txn_lazy {
	my ($self) = @_;
	return if $self->{txn};
	my $xdb = $self->{xdb} || $self->_xdb_acquire;
	$xdb->begin_transaction;
	$self->{txn} = 1;
}

sub commit_txn_lazy {
	my ($self) = @_;
	delete $self->{txn} or return;
	$self->{xdb}->commit_transaction;
}

sub worker_done {
	my ($self) = @_;
	die "$$ $0 xdb not released\n" if $self->{xdb};
	die "$$ $0 still in transaction\n" if $self->{txn};
}

1;
