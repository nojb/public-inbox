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
use Fcntl qw(:flock :DEFAULT);
use PublicInbox::MIME;
use base qw(PublicInbox::Search);
use PublicInbox::MID qw/mid_clean id_compress mid_mime/;
use PublicInbox::MsgIter;
use Carp qw(croak);
use POSIX qw(strftime);
require PublicInbox::Git;

use constant {
	MAX_MID_SIZE => 244, # max term size - 1 in Xapian
	PERM_UMASK => 0,
	OLD_PERM_GROUP => 1,
	OLD_PERM_EVERYBODY => 2,
	PERM_GROUP => 0660,
	PERM_EVERYBODY => 0664,
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
		$git = $ibx->git;
	} else {
		$git = PublicInbox::Git->new($git_dir); # v1 only
	}
	require Search::Xapian::WritableDatabase;
	my $self = bless {
		mainrepo => $mainrepo,
		git => $git,
		-altid => $altid,
		version => $version,
	}, $class;
	my $perm = $self->_git_config_perm;
	my $umask = _umask_for($perm);
	$self->{umask} = $umask;
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
	_lock_release($self) if $self->{creat};
	undef;
}

sub _xdb_acquire {
	my ($self) = @_;
	croak 'already acquired' if $self->{xdb};
	my $dir = $self->xdir;
	my $flag = Search::Xapian::DB_OPEN;
	if ($self->{creat}) {
		require File::Path;
		_lock_acquire($self);
		File::Path::mkpath($dir);
		$flag = Search::Xapian::DB_CREATE_OR_OPEN;
	}
	$self->{xdb} = Search::Xapian::WritableDatabase->new($dir, $flag);
}

# we only acquire the flock if creating or reindexing;
# PublicInbox::Import already has the lock on its own.
sub _lock_acquire {
	my ($self) = @_;
	croak 'already locked' if $self->{lockfh};
	my $lock_path = $self->{lock_path} or return;
	sysopen(my $lockfh, $lock_path, O_WRONLY|O_CREAT) or
		die "failed to open lock $lock_path: $!\n";
	flock($lockfh, LOCK_EX) or die "lock failed: $!\n";
	$self->{lockfh} = $lockfh;
}

sub _lock_release {
	my ($self) = @_;
	return unless $self->{lock_path};
	my $lockfh = delete $self->{lockfh} or croak 'not locked';
	flock($lockfh, LOCK_UN) or die "unlock failed: $!\n";
	close $lockfh or die "close failed: $!\n";
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

	my $yyyymmdd = strftime('%Y%m%d', gmtime($ts));
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

sub index_text_inc ($$$) {
	my ($tg, $text, $pfx) = @_;
	$tg->index_text($text, 1, $pfx);
	$tg->increase_termpos;
}

sub index_old_diff_fn {
	my ($tg, $seen, $fa, $fb) = @_;

	# no renames or space support for traditional diffs,
	# find the number of leading common paths to strip:
	my @fa = split('/', $fa);
	my @fb = split('/', $fb);
	while (scalar(@fa) && scalar(@fb)) {
		$fa = join('/', @fa);
		$fb = join('/', @fb);
		if ($fa eq $fb) {
			index_text_inc($tg, $fa,'XDFN') unless $seen->{$fa}++;
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
	foreach (@$lines) {
		if ($in_diff && s/^ //) { # diff context
			index_text_inc($tg, $_, 'XDFCTX');
		} elsif (/^-- $/) { # email signature begins
			$in_diff = undef;
		} elsif (m!^diff --git ("?a/.+) ("?b/.+)\z!) {
			my ($fa, $fb) = ($1, $2);
			my $fn = (split('/', git_unquote($fa), 2))[1];
			index_text_inc($tg, $fn, 'XDFN') unless $seen{$fn}++;
			$fn = (split('/', git_unquote($fb), 2))[1];
			index_text_inc($tg, $fn, 'XDFN') unless $seen{$fn}++;
			$in_diff = 1;
		# traditional diff:
		} elsif (m/^diff -(.+) (\S+) (\S+)$/) {
			my ($opt, $fa, $fb) = ($1, $2, $3);
			# only support unified:
			next unless $opt =~ /[uU]/;
			$in_diff = index_old_diff_fn($tg, \%seen, $fa, $fb);
		} elsif (m!^--- ("?a/.+)!) {
			my $fn = (split('/', git_unquote($1), 2))[1];
			index_text_inc($tg, $fn, 'XDFN') unless $seen{$fn}++;
			$in_diff = 1;
		} elsif (m!^\+\+\+ ("?b/.+)!)  {
			my $fn = (split('/', git_unquote($1), 2))[1];
			index_text_inc($tg, $fn, 'XDFN') unless $seen{$fn}++;
			$in_diff = 1;
		} elsif (/^--- (\S+)/) {
			$in_diff = $1;
		} elsif (defined $in_diff && /^\+\+\+ (\S+)/) {
			$in_diff = index_old_diff_fn($tg, \%seen, $in_diff, $1);
		} elsif ($in_diff && s/^\+//) { # diff added
			index_text_inc($tg, $_, 'XDFB');
		} elsif ($in_diff && s/^-//) { # diff removed
			index_text_inc($tg, $_, 'XDFA');
		} elsif (m!^index ([a-f0-9]+)\.\.([a-f0-9]+)!) {
			my ($ba, $bb) = ($1, $2);
			index_git_blob_id($doc, 'XDFPRE', $ba);
			index_git_blob_id($doc, 'XDFPOST', $bb);
			$in_diff = 1;
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*$/) {
			# traditional diff w/o -p
		} elsif (/^@@ (?:\S+) (?:\S+) @@\s*(\S+.*)$/) {
			# hunk header context
			index_text_inc($tg, $1, 'XDFHH');
		# ignore the following lines:
		} elsif (/^(?:dis)similarity index/) {
		} elsif (/^(?:old|new) mode/) {
		} elsif (/^(?:deleted|new) file mode/) {
		} elsif (/^(?:copy|rename) (?:from|to) /) {
		} elsif (/^(?:dis)?similarity index /) {
		} elsif (/^\\ No newline at end of file/) {
		} elsif (/^Binary files .* differ/) {
		} elsif ($_ eq '') {
			$in_diff = undef;
		} else {
			warn "non-diff line: $_\n" if DEBUG && $_ ne '';
			$in_diff = undef;
		}
	}
}

sub index_body ($$$) {
	my ($tg, $lines, $doc) = @_;
	my $txt = join("\n", @$lines);
	$tg->index_text($txt, !!$doc, $doc ? 'XNQ' : 'XQUOT');
	$tg->increase_termpos;
	# does it look like a diff?
	if ($doc && $txt =~ /^(?:diff|---|\+\+\+) /ms) {
		$txt = undef;
		index_diff($tg, $lines, $doc);
	}
	@$lines = ();
}

sub add_message {
	my ($self, $mime, $bytes, $num, $blob) = @_; # mime = Email::MIME object
	my $db = $self->{xdb};

	my ($doc_id, $old_tid);
	my $mid = mid_clean(mid_mime($mime));
	my $threader = $self->{threader};

	eval {
		die 'Message-ID too long' if length($mid) > MAX_MID_SIZE;
		my $smsg = $self->lookup_message($mid);
		if ($smsg) {
			# convert a ghost to a regular message
			# it will also clobber any existing regular message
			$doc_id = $smsg->{doc_id};
			$old_tid = $smsg->thread_id unless $threader;
		}
		$smsg = PublicInbox::SearchMsg->new($mime);
		my $doc = $smsg->{doc};
		$doc->add_term('XMID' . $mid);

		my $subj = $smsg->subject;
		my $xpath;
		if ($subj ne '') {
			$xpath = $self->subject_path($subj);
			$xpath = id_compress($xpath);
			$doc->add_term('XPATH' . $xpath);
		}

		my $lines = $mime->body_raw =~ tr!\n!\n!;
		my @values = ($smsg->ts, $num, $bytes, $lines);
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
		my $data = $smsg->to_doc_data($blob);
		if ($threader) {
			push @values, $mid, $xpath, $data;
			$threader->thread_msg(\@values);
		} else {
			link_message($self, $smsg, $refs, $old_tid);
		}
		$tg->index_text($mid, 1, 'XM');
		$doc->set_data($data);

		if (my $altid = $self->{-altid}) {
			foreach my $alt (@$altid) {
				my $id = $alt->mid2alt($mid);
				next unless defined $id;
				$doc->add_term($alt->{xprefix} . $id);
			}
		}
		if (defined $doc_id) {
			$db->replace_document($doc_id, $doc);
		} else {
			$doc_id = $db->add_document($doc);
		}
	};

	if ($@) {
		warn "failed to index message <$mid>: $@\n";
		return undef;
	}
	$doc_id;
}

# returns deleted doc_id on success, undef on missing
sub remove_message {
	my ($self, $mid) = @_;
	my $db = $self->{xdb};
	my $doc_id;
	$mid = mid_clean($mid);

	eval {
		my ($head, $tail) = $self->find_doc_ids('XMID' . $mid);
		if ($head->equal($tail)) {
			warn "cannot remove non-existent <$mid>\n";
		}
		for (; $head != $tail; $head->inc) {
			my $docid = $head->get_docid;
			$db->delete_document($docid);
		}
	};

	if ($@) {
		warn "failed to remove message <$mid>: $@\n";
		return undef;
	}
	$doc_id;
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
	my $doc = $smsg->{doc};
	my $mid = $smsg->mid;
	my $mime = $smsg->{mime};
	my $hdr = $mime->header_obj;

	# last References should be IRT, but some mail clients do things
	# out of order, so trust IRT over References iff IRT exists
	my @refs = (($hdr->header_raw('References') || '') =~ /<([^>]+)>/g);
	push(@refs, (($hdr->header_raw('In-Reply-To') || '') =~ /<([^>]+)>/g));

	if (@refs) {
		my %uniq = ($mid => 1);
		my @orig_refs = @refs;
		@refs = ();

		# prevent circular references via References: here:
		foreach my $ref (@orig_refs) {
			if (length($ref) > MAX_MID_SIZE) {
				warn "References: <$ref> too long, ignoring\n";
			}
			next if $uniq{$ref};
			$uniq{$ref} = 1;
			push @refs, $ref;
		}
	}
	$smsg->{references} = '<'.join('> <', @refs).'>' if @refs;
	\@refs
}

sub link_message {
	my ($self, $smsg, $refs, $old_tid) = @_;
	my $tid;

	if (@$refs) {

		# first ref *should* be the thread root,
		# but we can never trust clients to do the right thing
		my $ref = shift @$refs;
		$tid = $self->_resolve_mid_to_tid($ref);
		$self->merge_threads($tid, $old_tid) if defined $old_tid;

		# the rest of the refs should point to this tid:
		foreach $ref (@$refs) {
			my $ptid = $self->_resolve_mid_to_tid($ref);
			merge_threads($self, $tid, $ptid);
		}
	} else {
		$tid = defined $old_tid ? $old_tid : $self->next_thread_id;
	}
	$smsg->{doc}->add_term('G' . $tid);
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
	my ($self, $mime, $warn_existing) = @_;
	my $mid = mid_clean(mid_mime($mime));
	my $mm = $self->{mm};
	my $num = $mm->mid_insert($mid);
	return $num if defined $num;

	warn "<$mid> reused\n" if $warn_existing;
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
	with_umask($self, sub { $self->_index_sync($opts) });
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
sub _resolve_mid_to_tid {
	my ($self, $mid) = @_;

	my $smsg = $self->lookup_message($mid) || $self->create_ghost($mid);
	$smsg->thread_id;
}

sub create_ghost {
	my ($self, $mid) = @_;

	my $tid = $self->next_thread_id;
	my $doc = Search::Xapian::Document->new;
	$doc->add_term('XMID' . $mid);
	$doc->add_term('G' . $tid);
	$doc->add_term('T' . 'ghost');

	my $smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
	$self->{xdb}->add_document($doc);

	$smsg;
}

sub merge_threads {
	my ($self, $winner_tid, $loser_tid) = @_;
	return if $winner_tid == $loser_tid;
	my ($head, $tail) = $self->find_doc_ids('G' . $loser_tid);
	my $db = $self->{xdb};

	for (; $head != $tail; $head->inc) {
		my $docid = $head->get_docid;
		my $doc = $db->get_document($docid);
		$doc->remove_term('G' . $loser_tid);
		$doc->add_term('G' . $winner_tid);
		$db->replace_document($docid, $doc);
	}
}

sub _read_git_config_perm {
	my ($self) = @_;
	my @cmd = qw(config);
	if ($self->{version} == 2) {
		push @cmd, "--file=$self->{mainrepo}/inbox-config";
	}
	my $fh = $self->{git}->popen(@cmd, 'core.sharedRepository');
	local $/ = "\n";
	my $perm = <$fh>;
	chomp $perm if defined $perm;
	$perm;
}

sub _git_config_perm {
	my $self = shift;
	my $perm = scalar @_ ? $_[0] : _read_git_config_perm($self);
	return PERM_GROUP if (!defined($perm) || $perm eq '');
	return PERM_UMASK if ($perm eq 'umask');
	return PERM_GROUP if ($perm eq 'group');
	if ($perm =~ /\A(?:all|world|everybody)\z/) {
		return PERM_EVERYBODY;
	}
	return PERM_GROUP if ($perm =~ /\A(?:true|yes|on|1)\z/);
	return PERM_UMASK if ($perm =~ /\A(?:false|no|off|0)\z/);

	my $i = oct($perm);
	return PERM_UMASK if ($i == PERM_UMASK);
	return PERM_GROUP if ($i == OLD_PERM_GROUP);
	return PERM_EVERYBODY if ($i == OLD_PERM_EVERYBODY);

	if (($i & 0600) != 0600) {
		die "core.sharedRepository mode invalid: ".
		    sprintf('%.3o', $i) . "\nOwner must have permissions\n";
	}
	($i & 0666);
}

sub _umask_for {
	my ($perm) = @_; # _git_config_perm return value
	my $rv = $perm;
	return umask if $rv == 0;

	# set +x bit if +r or +w were set
	$rv |= 0100 if ($rv & 0600);
	$rv |= 0010 if ($rv & 0060);
	$rv |= 0001 if ($rv & 0006);
	(~$rv & 0777);
}

sub with_umask {
	my ($self, $cb) = @_;
	my $old = umask $self->{umask};
	my $rv = eval { $cb->() };
	my $err = $@;
	umask $old;
	die $err if $err;
	$rv;
}

sub DESTROY {
	# order matters for unlocking
	$_[0]->{xdb} = undef;
	$_[0]->{lockfh} = undef;
}

# remote_* subs are only used by SearchIdxPart and SearchIdxThread:
sub remote_commit {
	my ($self) = @_;
	print { $self->{w} } "commit\n" or die "failed to write commit: $!";
}

sub remote_close {
	my ($self) = @_;
	my $pid = delete $self->{pid} or die "no process to wait on\n";
	my $w = delete $self->{w} or die "no pipe to write to\n";
	print $w "close\n" or die "failed to write to pid:$pid: $!\n";
	close $w or die "failed to close pipe for pid:$pid: $!\n";
	waitpid($pid, 0) == $pid or die "remote process did not finish";
	$? == 0 or die ref($self)." exited with: $?";
}

1;
