# Copyright (C) 2015-2019 all contributors <meta@public-inbox.org>
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
use PublicInbox::MID qw/mid_clean mid_mime mids_for_index/;
use PublicInbox::MsgIter;
use Carp qw(croak);
use POSIX qw(strftime);
use PublicInbox::OverIdx;
use PublicInbox::Spawn qw(spawn);
use PublicInbox::Git qw(git_unquote);
my $X = \%PublicInbox::Search::X;
my ($DB_CREATE_OR_OPEN, $DB_OPEN);
use constant {
	BATCH_BYTES => defined($ENV{XAPIAN_FLUSH_THRESHOLD}) ?
			0x7fffffff : 1_000_000,
	DEBUG => !!$ENV{DEBUG},
};

my $xapianlevels = qr/\A(?:full|medium)\z/;

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
		inboxdir => $inboxdir,
		-inbox => $ibx,
		git => $ibx->git,
		-altid => $altid,
		ibx_ver => $version,
		indexlevel => $indexlevel,
	}, $class;
	$ibx->umask_prepare;
	if ($version == 1) {
		$self->{lock_path} = "$inboxdir/ssoma.lock";
		my $dir = $self->xdir;
		$self->{over} = PublicInbox::OverIdx->new("$dir/over.sqlite3");
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

sub _xdb_release {
	my ($self) = @_;
	if (need_xapian($self)) {
		my $xdb = delete $self->{xdb} or croak 'not acquired';
		$xdb->close;
	}
	$self->lock_release if $self->{creat};
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

sub _xdb_acquire {
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

sub index_users ($$) {
	my ($self, $smsg) = @_;

	my $from = $smsg->from;
	my $to = $smsg->to;
	my $cc = $smsg->cc;

	index_text($self, $from, 1, 'A'); # A - author
	index_text($self, $to, 1, 'XTO') if $to ne '';
	index_text($self, $cc, 1, 'XCC') if $cc ne '';
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
		} elsif (m!^--- ("?a/.+)!) {
			my $fn = $1;
			$fn = (split('/', git_unquote($fn), 2))[1];
			$seen{$fn}++ or index_diff_inc($self, $fn, 'XDFN', $xnq);
			$in_diff = 1;
		} elsif (m!^\+\+\+ ("?b/.+)!)  {
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

sub index_body ($$$) {
	my ($self, $txt, $doc) = @_;
	if ($doc) {
		# does it look like a diff?
		if ($txt =~ /^(?:diff|---|\+\+\+) /ms) {
			index_diff($self, $txt, $doc);
		} else {
			index_text($self, $txt, 1, 'XNQ');
		}
	} else {
		index_text($self, $txt, 0, 'XQUOT');
	}
}

sub index_xapian { # msg_iter callback
	my ($part, $depth, @idx) = @{$_[0]};
	my ($self, $doc) = @{$_[1]};
	my $ct = $part->content_type || 'text/plain';
	my $fn = $part->filename;
	if (defined $fn && $fn ne '') {
		index_text($self, $fn, 1, 'XFN');
	}

	my ($s, undef) = msg_part_text($part, $ct);
	defined $s or return;

	# split off quoted and unquoted blocks:
	my @sections = split(/((?:^>[^\n]*\n)+)/sm, $s);
	$part = $s = undef;
	index_body($self, $_, /\A>/ ? 0 : $doc) for @sections;
}

sub add_xapian ($$$$$$) {
	my ($self, $mime, $num, $oid, $mids, $mid0) = @_;
	my $smsg = PublicInbox::SearchMsg->new($mime);
	my $doc = $X->{Document}->new;
	my $subj = $smsg->subject;
	add_val($doc, PublicInbox::Search::TS(), $smsg->ts);
	my @ds = gmtime($smsg->ds);
	my $yyyymmdd = strftime('%Y%m%d', @ds);
	add_val($doc, PublicInbox::Search::YYYYMMDD(), $yyyymmdd);
	my $dt = strftime('%Y%m%d%H%M%S', @ds);
	add_val($doc, PublicInbox::Search::DT(), $dt);

	my $tg = term_generator($self);

	$tg->set_document($doc);
	index_text($self, $subj, 1, 'S') if $subj;
	index_users($self, $smsg);

	msg_iter($mime, \&index_xapian, [ $self, $doc ]);
	foreach my $mid (@$mids) {
		index_text($self, $mid, 1, 'XM');

		# because too many Message-IDs are prefixed with
		# "Pine.LNX."...
		if ($mid =~ /\w{12,}/) {
			my @long = ($mid =~ /(\w{3,}+)/g);
			index_text($self, join(' ', @long), 1, 'XM');
		}
	}
	$smsg->{to} = $smsg->{cc} = '';
	PublicInbox::OverIdx::parse_references($smsg, $mid0, $mids);
	my $data = $smsg->to_doc_data($oid, $mid0);
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
	$doc->add_boolean_term('Q' . $_) foreach @$mids;
	$self->{xdb}->replace_document($num, $doc);
}

sub _msgmap_init ($) {
	my ($self) = @_;
	die "BUG: _msgmap_init is only for v1\n" if $self->{ibx_ver} != 1;
	$self->{mm} //= eval {
		require PublicInbox::Msgmap;
		PublicInbox::Msgmap->new($self->{inboxdir}, 1);
	};
}

sub add_message {
	# mime = Email::MIME object
	my ($self, $mime, $bytes, $num, $oid, $mid0) = @_;
	my $mids = mids_for_index($mime->header_obj);
	$mid0 //= $mids->[0]; # v1 compatibility
	$num //= do { # v1
		_msgmap_init($self);
		index_mm($self, $mime);
	};
	eval {
		if (need_xapian($self)) {
			add_xapian($self, $mime, $num, $oid, $mids, $mid0);
		}
		if (my $over = $self->{over}) {
			$over->add_overview($mime, $bytes, $num, $oid, $mid0);
		}
	};

	if ($@) {
		warn "failed to index message <".join('> <',@$mids).">: $@\n";
		return undef;
	}
	$num;
}

# returns begin and end PostingIterator
sub find_doc_ids {
	my ($self, $termval) = @_;
	my $db = $self->{xdb};

	($db->postlist_begin($termval), $db->postlist_end($termval));
}

# v1 only
sub batch_do {
	my ($self, $termval, $cb) = @_;
	my $batch_size = 1000; # don't let @ids grow too large to avoid OOM
	while (1) {
		my ($head, $tail) = $self->find_doc_ids($termval);
		return if $head == $tail;
		my @ids;
		for (; $head != $tail && @ids < $batch_size; $head++) {
			push @ids, $head->get_docid;
		}
		$cb->(\@ids);
	}
}

# v1 only, where $mid is unique
sub remove_message {
	my ($self, $mid) = @_;
	$mid = mid_clean($mid);

	if (my $over = $self->{over}) {
		my $nr = eval { $over->remove_oid(undef, $mid) };
		if ($@) {
			warn "failed to remove <$mid> from overview: $@\n";
		} elsif ($nr == 0) {
			warn "<$mid> missing for removal from overview\n";
		}
	}
	return unless need_xapian($self);
	my $db = $self->{xdb};
	my $nr = 0;
	eval {
		batch_do($self, 'Q' . $mid, sub {
			my ($ids) = @_;
			$db->delete_document($_) for @$ids;
			$nr += scalar @$ids;
		});
	};
	if ($@) {
		warn "failed to remove <$mid> from Xapian: $@\n";
	} elsif ($nr == 0) {
		warn "<$mid> missing for removal from Xapian\n";
	}
}

# MID is a hint in V2
sub remove_by_oid {
	my ($self, $oid, $mid) = @_;

	$self->{over}->remove_oid($oid, $mid) if $self->{over};

	return unless need_xapian($self);
	my $db = $self->{xdb};

	# XXX careful, we cannot use batch_do here since we conditionally
	# delete documents based on other factors, so we cannot call
	# find_doc_ids twice.
	my ($head, $tail) = $self->find_doc_ids('Q' . $mid);
	return if $head == $tail;

	# there is only ONE element in @delete unless we
	# have bugs in our v2writable deduplication check
	my @delete;
	for (; $head != $tail; $head++) {
		my $docid = $head->get_docid;
		my $doc = $db->get_document($docid);
		my $smsg = PublicInbox::SearchMsg->wrap($mid);
		$smsg->load_expand($doc);
		if ($smsg->{blob} eq $oid) {
			push(@delete, $docid);
		}
	}
	$db->delete_document($_) foreach @delete;
	scalar(@delete);
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
	my $num;

	if (defined $self->{regen_down}) {
		$num = $mm->num_for($mid) and return $num;

		while (($num = $self->{regen_down}--) > 0) {
			if ($mm->mid_set($num, $mid) != 0) {
				return $num;
			}
		}
	} elsif (defined $self->{regen_up}) {
		$num = $mm->num_for($mid) and return $num;

		# this is to fixup old bugs due to add-remove-add
		while (($num = ++$self->{regen_up})) {
			if ($mm->mid_set($num, $mid) != 0) {
				return $num;
			}
		}
	}

	$num = $mm->mid_insert($mid) and return $num;

	# fallback to num_for since filters like RubyLang set the number
	$mm->num_for($mid);
}

sub unindex_mm {
	my ($self, $mime) = @_;
	$self->{mm}->mid_delete(mid_clean(mid_mime($mime)));
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

# called by public-inbox-index
sub index_sync {
	my ($self, $opts) = @_;
	delete $self->{lock_path} if $opts->{-skip_lock};
	$self->{-inbox}->with_umask(sub { $self->_index_sync($opts) })
}

sub batch_adjust ($$$$$) {
	my ($max, $bytes, $batch_cb, $latest, $nr) = @_;
	$$max -= $bytes;
	if ($$max <= 0) {
		$$max = BATCH_BYTES;
		$batch_cb->($nr, $latest);
	}
}

# only for v1
sub read_log {
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
	my %D;
	my $line;
	my $newest;
	my $nr = 0;
	while (defined($line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $blob = $1;
			if (delete $D{$blob}) {
				if (defined $self->{regen_down}) {
					my $num = $self->{regen_down}--;
					$self->{mm}->num_highwater($num);
				}
				next;
			}
			my $mime = do_cat_mail($git, $blob, \$bytes) or next;
			batch_adjust(\$max, $bytes, $batch_cb, $latest, ++$nr);
			$add_cb->($self, $mime, $bytes, $blob);
		} elsif ($line =~ /$delmsg/o) {
			my $blob = $1;
			$D{$blob} = 1;
		} elsif ($line =~ /^commit ($h40)/o) {
			$latest = $1;
			$newest ||= $latest;
		}
	}
	close($log) or die "git log failed: \$?=$?";
	# get the leftovers
	foreach my $blob (keys %D) {
		my $mime = do_cat_mail($git, $blob, \$bytes) or next;
		$del_cb->($self, $mime);
	}
	$batch_cb->($nr, $latest, $newest);
}

sub _git_log {
	my ($self, $opts, $range) = @_;
	my $git = $self->{git};

	if (index($range, '..') < 0) {
		# don't show annoying git errrors to users who run -index
		# on empty inboxes
		$git->qx(qw(rev-parse -q --verify), "$range^0");
		if ($?) {
			open my $fh, '<', '/dev/null' or
				die "failed to open /dev/null: $!\n";
			return $fh;
		}
	}

	# Count the new files so they can be added newest to oldest
	# and still have numbers increasing from oldest to newest
	my $fcount = 0;
	my $pr = $opts->{-progress};
	$pr->("counting changes\n\t$range ... ") if $pr;
	# can't use 'rev-list --count' if we use --diff-filter
	my $fh = $git->popen(qw(log --pretty=tformat:%h
			     --no-notes --no-color --no-renames
			     --diff-filter=AM), $range);
	++$fcount while <$fh>;
	close $fh or die "git log failed: \$?=$?";
	my $high = $self->{mm}->num_highwater;
	$pr->("$fcount\n") if $pr; # continue previous line
	$self->{ntodo} = $fcount;

	if (index($range, '..') < 0) {
		if ($high && $high == $fcount) {
			# fix up old bugs in full indexes which caused messages to
			# not appear in Msgmap
			$self->{regen_up} = $high;
		} else {
			# normal regen is for for fresh data
			$self->{regen_down} = $fcount;
		}
	} else {
		# Give oldest messages the smallest numbers
		$self->{regen_down} = $high + $fcount;
	}

	$git->popen(qw/log --no-notes --no-color --no-renames
				--raw -r --no-abbrev/, $range);
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
	my $git = $self->{git};
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
	if (!$lm || ($lx && $lm && is_ancestor($self->{git}, $lm, $lx))) {
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
	my ($last_commit, $lx, $xlog);
	my $git = $self->{git};
	$git->batch_prepare;
	my $pr = $opts->{-progress};

	my $xdb = $self->begin_txn_lazy;
	my $mm = _msgmap_init($self);
	do {
		if ($xlog) {
			close($xlog) or die "git log failed: \$?=$?";
			$xlog = undef;
		}
		$last_commit = _last_x_commit($self, $mm);
		$lx = reindex_from($opts->{reindex}, $last_commit);

		$self->{over}->rollback_lazy;
		$self->{over}->disconnect;
		$git->cleanup;
		delete $self->{txn};
		$xdb->cancel_transaction if $xdb;
		$xdb = _xdb_release($self);

		# ensure we leak no FDs to "git log" with Xapian <= 1.2
		my $range = $lx eq '' ? $tip : "$lx..$tip";
		$xlog = _git_log($self, $opts, $range);

		$xdb = $self->begin_txn_lazy;
	} while (_last_x_commit($self, $mm) ne $last_commit);

	my $dbh = $mm->{dbh} if $mm;
	my $cb = sub {
		my ($nr, $commit, $newest) = @_;
		if ($dbh) {
			if ($newest) {
				my $cur = $mm->last_commit || '';
				if (need_update($self, $cur, $newest)) {
					$mm->last_commit($newest);
				}
			}
			$dbh->commit;
		}
		if ($newest && need_xapian($self)) {
			my $cur = $xdb->get_metadata('last_commit');
			if (need_update($self, $cur, $newest)) {
				$xdb->set_metadata('last_commit', $newest);
			}
		}
		$self->commit_txn_lazy;
		$git->cleanup;
		$xdb = _xdb_release($self);
		# let another process do some work... <
		$pr->("indexed $nr/$self->{ntodo}\n") if $pr && $nr;
		if (!$newest) {
			$xdb = $self->begin_txn_lazy;
			$dbh->begin_work if $dbh;
		}
	};

	$dbh->begin_work;
	read_log($self, $xlog, *index_both, *unindex_both, $cb);
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
		$self->_xdb_release if $self->{xdb};
	}
}

sub remote_remove {
	my ($self, $oid, $mid) = @_;
	if (my $w = $self->{w}) {
		# triggers remove_by_oid in a shard
		print $w "D $oid $mid\n" or die "failed to write remove $!";
	} else {
		$self->begin_txn_lazy;
		$self->remove_by_oid($oid, $mid);
	}
}

sub begin_txn_lazy {
	my ($self) = @_;
	return if $self->{txn};

	$self->{-inbox}->with_umask(sub {
		my $xdb = $self->{xdb} || $self->_xdb_acquire;
		$self->{over}->begin_lazy if $self->{over};
		$xdb->begin_transaction if $xdb;
		$self->{txn} = 1;
		$xdb;
	});
}

sub commit_txn_lazy {
	my ($self) = @_;
	delete $self->{txn} or return;
	$self->{-inbox}->with_umask(sub {
		if (my $xdb = $self->{xdb}) {

			# store 'indexlevel=medium' in v2 shard=0 and
			# v1 (only one shard)
			# This metadata is read by Admin::detect_indexlevel:
			if (!$self->{shard} # undef or 0, not >0
			    && $self->{indexlevel} eq 'medium') {
				$xdb->set_metadata('indexlevel', 'medium');
			}

			$xdb->commit_transaction;
		}
		$self->{over}->commit_lazy if $self->{over};
	});
}

sub worker_done {
	my ($self) = @_;
	if (need_xapian($self)) {
		die "$$ $0 xdb not released\n" if $self->{xdb};
	}
	die "$$ $0 still in transaction\n" if $self->{txn};
}

1;
