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
use PublicInbox::MID qw/mid_clean id_compress mid_mime mids/;
use PublicInbox::MsgIter;
use Carp qw(croak);
use POSIX qw(strftime);
use PublicInbox::OverIdx;
use PublicInbox::Spawn qw(spawn);
require PublicInbox::Git;
use Compress::Zlib qw(compress);

use constant {
	BATCH_BYTES => 10_000_000,
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
		my $dir = $self->xdir;
		$self->{over} = PublicInbox::OverIdx->new("$dir/over.sqlite3");
	} elsif ($version == 2) {
		defined $part or die "partition is required for v2\n";
		# partition is a number
		$self->{partition} = $part;
		$self->{lock_path} = undef;
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
	$mid0 = $mids->[0] unless defined $mid0; # v1 compatibility
	unless (defined $num) { # v1
		$self->_msgmap_init;
		$num = index_mm($self, $mime);
	}
	eval {
		my $smsg = PublicInbox::SearchMsg->new($mime);
		my $doc = $smsg->{doc};
		my $subj = $smsg->subject;
		add_val($doc, PublicInbox::Search::TS(), $smsg->ts);
		my @ds = gmtime($smsg->ds);
		my $yyyymmdd = strftime('%Y%m%d', @ds);
		add_val($doc, PublicInbox::Search::YYYYMMDD(), $yyyymmdd);
		my $dt = strftime('%Y%m%d%H%M%S', @ds);
		add_val($doc, PublicInbox::Search::DT(), $dt);

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

		foreach my $mid (@$mids) {
			$tg->index_text($mid, 1, 'XM');
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

		if (my $over = $self->{over}) {
			$over->add_overview($mime, $bytes, $num, $oid, $mid0);
		}
		$doc->add_boolean_term('Q' . $_) foreach @$mids;
		$self->{xdb}->replace_document($doc_id = $num, $doc);
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
	my $over = $self->{over};

	eval {
		batch_do($self, 'Q' . $mid, sub {
			my ($ids) = @_;
			$db->delete_document($_) for @$ids;
			$over->delete_articles($ids) if $over;
			$called = 1;
		});
	};
	if ($@) {
		warn "failed to remove message <$mid>: $@\n";
	} elsif (!$called) {
		warn "cannot remove non-existent <$mid>\n";
	}
}

# MID is a hint in V2
sub remove_by_oid {
	my ($self, $oid, $mid) = @_;
	my $db = $self->{xdb};

	$self->{over}->remove_oid($oid, $mid) if $self->{over};

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
		if ($smsg->{blob} eq $oid) {
			push(@delete, $docid);
		}
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

sub index_sync {
	my ($self, $opts) = @_;
	$self->{-inbox}->with_umask(sub { $self->_index_sync($opts) })
}

sub batch_adjust ($$$$) {
	my ($max, $bytes, $batch_cb, $latest) = @_;
	$$max -= $bytes;
	if ($$max <= 0) {
		$$max = BATCH_BYTES;
		$batch_cb->($latest);
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
	my $mid = '20170114215743.5igbjup6qpsh3jfg@genre.crustytoothpaste.net';
	while (defined($line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $blob = $1;
			delete $D{$blob} and next;
			my $mime = do_cat_mail($git, $blob, \$bytes) or next;
			my $mids = mids($mime->header_obj);
			foreach (@$mids) {
				warn "ADD $mid\n" if ($_ eq $mid);
			}
			batch_adjust(\$max, $bytes, $batch_cb, $latest);
			$add_cb->($self, $mime, $bytes, $blob);
		} elsif ($line =~ /$delmsg/o) {
			my $blob = $1;
			$D{$blob} = 1;
		} elsif ($line =~ /^commit ($h40)/o) {
			$latest = $1;
			$newest ||= $latest;
		}
	}
	# get the leftovers
	foreach my $blob (keys %D) {
		my $mime = do_cat_mail($git, $blob, \$bytes) or next;
		my $mids = mids($mime->header_obj);
		foreach (@$mids) {
			warn "DEL $mid\n" if ($_ eq $mid);
		}
		$del_cb->($self, $mime);
	}
	$batch_cb->($latest, $newest);
}

sub _msgmap_init {
	my ($self) = @_;
	die "BUG: _msgmap_init is only for v1\n" if $self->{version} != 1;
	$self->{mm} ||= eval {
		require PublicInbox::Msgmap;
		PublicInbox::Msgmap->new($self->{mainrepo}, 1);
	};
}

sub _git_log {
	my ($self, $range) = @_;
	my $git = $self->{git};

	if (index($range, '..') < 0) {
		my $regen_max = 0;
		# can't use 'rev-list --count' if we use --diff-filter
		my $fh = $git->popen(qw(log --pretty=tformat:%h
				--no-notes --no-color --no-renames
				--diff-filter=AM), $range);
		++$regen_max while <$fh>;
		my (undef, $max) = $self->{mm}->minmax;

		if ($max && $max == $regen_max) {
			# fix up old bugs in full indexes which caused messages to
			# not appear in Msgmap
			$self->{regen_up} = $max;
		} else {
			# normal regen is for for fresh data
			$self->{regen_down} = $regen_max;
		}
	}

	$git->popen(qw/log --no-notes --no-color --no-renames
				--raw -r --no-abbrev/, $range);
}

sub is_ancestor ($$$) {
	my ($git, $cur, $tip) = @_;
	return 0 unless $git->check($cur);
	my $cmd = [ 'git', "--git-dir=$git->{git_dir}",
		qw(merge-base --is-ancestor), $cur, $tip ];
	my $pid = spawn($cmd);
	defined $pid or die "spawning ".join(' ', @$cmd)." failed: $!";
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

# indexes all unindexed messages (v1 only)
sub _index_sync {
	my ($self, $opts) = @_;
	my $tip = $opts->{ref} || 'HEAD';
	my $reindex = $opts->{reindex};
	my ($mkey, $last_commit, $lx, $xlog);
	my $git = $self->{git};
	$git->batch_prepare;

	my $xdb = $self->begin_txn_lazy;
	my $mm = _msgmap_init($self);
	do {
		$xlog = undef;
		$mkey = 'last_commit';
		$last_commit = $xdb->get_metadata('last_commit');
		$lx = $last_commit;
		if ($reindex) {
			$lx = '';
			$mkey = undef if $last_commit ne '';
		}

		# use last_commit from msgmap if it is older or unset
		my $lm = $mm->last_commit || '';
		if (!$lm || ($lm && $lx && is_ancestor($git, $lm, $lx))) {
			$lx = $lm;
		}

		$self->{over}->rollback_lazy;
		$self->{over}->disconnect;
		delete $self->{txn};
		$xdb->cancel_transaction;
		$xdb = _xdb_release($self);

		# ensure we leak no FDs to "git log" with Xapian <= 1.2
		my $range = $lx eq '' ? $tip : "$lx..$tip";
		$xlog = _git_log($self, $range);

		$xdb = $self->begin_txn_lazy;
	} while ($xdb->get_metadata('last_commit') ne $last_commit);

	my $dbh = $mm->{dbh} if $mm;
	my $cb = sub {
		my ($commit, $newest) = @_;
		if ($dbh) {
			if ($newest) {
				my $cur = $mm->last_commit || '';
				if (need_update($self, $cur, $newest)) {
					$mm->last_commit($newest);
				}
			}
			$dbh->commit;
		}
		if ($mkey && $newest) {
			my $cur = $xdb->get_metadata($mkey);
			if (need_update($self, $cur, $newest)) {
				$xdb->set_metadata($mkey, $newest);
			}
		}
		$self->commit_txn_lazy;
		# let another process do some work... <
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
		# triggers remove_by_oid in a partition
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
	$self->{over}->begin_lazy if $self->{over};
	$xdb->begin_transaction;
	$self->{txn} = 1;
	$xdb;
}

sub commit_txn_lazy {
	my ($self) = @_;
	delete $self->{txn} or return;
	$self->{xdb}->commit_transaction;
	$self->{over}->commit_lazy if $self->{over};
}

sub worker_done {
	my ($self) = @_;
	die "$$ $0 xdb not released\n" if $self->{xdb};
	die "$$ $0 still in transaction\n" if $self->{txn};
}

1;
