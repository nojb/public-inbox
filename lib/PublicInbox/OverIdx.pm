# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for XOVER, OVER in NNTP, and feeds/homepage/threads in PSGI
# Unlike Msgmap, this is an _UNSTABLE_ cache which can be
# tweaked/updated over time and rebuilt.
#
# Ghost messages (messages which are only referenced in References/In-Reply-To)
# are denoted by a negative NNTP article number.
package PublicInbox::OverIdx;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Over);
use IO::Handle;
use DBI qw(:sql_types); # SQL_BLOB
use PublicInbox::MID qw/id_compress mids_for_index references/;
use PublicInbox::Smsg qw(subject_normalized);
use Compress::Zlib qw(compress);
use Carp qw(croak);

sub dbh_new {
	my ($self) = @_;
	my $dbh = $self->SUPER::dbh_new($self->{-no_fsync} ? 2 : 1);

	# 80000 pages (80MiB on SQLite <3.12.0, 320MiB on 3.12.0+)
	# was found to be good in 2018 during the large LKML import
	# at the time.  This ought to be configurable based on HW
	# and inbox size; I suspect it's overkill for many inboxes.
	$dbh->do('PRAGMA cache_size = 80000');

	create_tables($dbh);
	$dbh;
}

sub new {
	my ($class, $f) = @_;
	my $self = $class->SUPER::new($f);
	$self->{min_tid} = 0;
	$self;
}

sub get_counter ($$) {
	my ($dbh, $key) = @_;
	my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT val FROM counter WHERE key = ? LIMIT 1

	$sth->execute($key);
	$sth->fetchrow_array;
}

sub adj_counter ($$$) {
	my ($self, $key, $op) = @_;
	my $dbh = $self->{dbh};
	my $sth = $dbh->prepare_cached(<<"");
UPDATE counter SET val = val $op 1 WHERE key = ?

	$sth->execute($key);

	get_counter($dbh, $key);
}

sub next_tid { adj_counter($_[0], 'thread', '+') }
sub next_ghost_num { adj_counter($_[0], 'ghost', '-') }

sub id_for ($$$$$) {
	my ($self, $tbl, $id_col, $val_col, $val) = @_;
	my $dbh = $self->{dbh};
	my $in = $dbh->prepare_cached(<<"")->execute($val);
INSERT OR IGNORE INTO $tbl ($val_col) VALUES (?)

	if ($in == 0) {
		my $sth = $dbh->prepare_cached(<<"", undef, 1);
SELECT $id_col FROM $tbl WHERE $val_col = ? LIMIT 1

		$sth->execute($val);
		$sth->fetchrow_array;
	} else {
		$dbh->last_insert_id(undef, undef, $tbl, $id_col);
	}
}

sub ibx_id {
	my ($self, $eidx_key) = @_;
	id_for($self, 'inboxes', 'ibx_id', eidx_key => $eidx_key);
}

sub sid {
	my ($self, $path) = @_;
	return unless defined $path && $path ne '';
	id_for($self, 'subject', 'sid', 'path' => $path);
}

sub mid2id {
	my ($self, $mid) = @_;
	id_for($self, 'msgid', 'id', 'mid' => $mid);
}

sub delete_by_num {
	my ($self, $num, $tid_ref) = @_;
	my $dbh = $self->{dbh};
	if ($tid_ref) {
		my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT tid FROM over WHERE num = ? LIMIT 1

		$sth->execute($num);
		$$tid_ref = $sth->fetchrow_array; # may be undef
	}
	foreach (qw(over id2num)) {
		$dbh->prepare_cached(<<"")->execute($num);
DELETE FROM $_ WHERE num = ?

	}
}

# this includes ghosts
sub each_by_mid {
	my ($self, $mid, $cols, $cb, @arg) = @_;
	my $dbh = $self->{dbh};

=over
	I originally wanted to stuff everything into a single query:

	SELECT over.* FROM over
	LEFT JOIN id2num ON over.num = id2num.num
	LEFT JOIN msgid ON msgid.id = id2num.id
	WHERE msgid.mid = ? AND over.num >= ?
	ORDER BY over.num ASC
	LIMIT 1000

	But it's faster broken out (and we're always in a
	transaction for subroutines in this file)
=cut

	my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT id FROM msgid WHERE mid = ? LIMIT 1

	$sth->execute($mid);
	my $id = $sth->fetchrow_array;
	defined $id or return;

	push(@$cols, 'num');
	$cols = join(',', map { $_ } @$cols);
	my $lim = 10;
	my $prev = get_counter($dbh, 'ghost');
	while (1) {
		$sth = $dbh->prepare_cached(<<"", undef, 1);
SELECT num FROM id2num WHERE id = ? AND num >= ?
ORDER BY num ASC
LIMIT $lim

		$sth->execute($id, $prev);
		my $nums = $sth->fetchall_arrayref;
		my $nr = scalar(@$nums) or return;
		$prev = $nums->[-1]->[0];

		$sth = $dbh->prepare_cached(<<"", undef, 1);
SELECT $cols FROM over WHERE over.num = ? LIMIT 1

		foreach (@$nums) {
			$sth->execute($_->[0]);
			my $smsg = $sth->fetchrow_hashref;
			$smsg = PublicInbox::Over::load_from_row($smsg);
			$cb->($self, $smsg, @arg) or return;
		}
		return if $nr != $lim;
	}
}

sub _resolve_mid_to_tid {
	my ($self, $smsg, $tid) = @_;
	my $cur_tid = $smsg->{tid};
	if (defined $$tid) {
		merge_threads($self, $$tid, $cur_tid);
	} elsif ($cur_tid > $self->{min_tid}) {
		$$tid = $cur_tid;
	} else { # rethreading, queue up dead ghosts
		$$tid = next_tid($self);
		my $n = $smsg->{num};
		if ($n > 0) {
			$self->{dbh}->prepare_cached(<<'')->execute($$tid, $n);
UPDATE over SET tid = ? WHERE num = ?

		} elsif ($n < 0) {
			push(@{$self->{-ghosts_to_delete}}, $n);
		}
	}
	1;
}

# this will create a ghost as necessary
sub resolve_mid_to_tid {
	my ($self, $mid) = @_;
	my $tid;
	each_by_mid($self, $mid, ['tid'], \&_resolve_mid_to_tid, \$tid);
	if (my $del = delete $self->{-ghosts_to_delete}) {
		delete_by_num($self, $_) for @$del;
	}
	$tid // do { # create a new ghost
		my $id = mid2id($self, $mid);
		my $num = next_ghost_num($self);
		$num < 0 or die "ghost num is non-negative: $num\n";
		$tid = next_tid($self);
		my $dbh = $self->{dbh};
		$dbh->prepare_cached(<<'')->execute($num, $tid);
INSERT INTO over (num, tid) VALUES (?,?)

		$dbh->prepare_cached(<<'')->execute($id, $num);
INSERT INTO id2num (id, num) VALUES (?,?)

		$tid;
	};
}

sub merge_threads {
	my ($self, $winner_tid, $loser_tid) = @_;
	return if $winner_tid == $loser_tid;
	my $dbh = $self->{dbh};
	$dbh->prepare_cached(<<'')->execute($winner_tid, $loser_tid);
UPDATE over SET tid = ? WHERE tid = ?

}

sub link_refs {
	my ($self, $refs, $old_tid) = @_;
	my $tid;

	if (@$refs) {
		# first ref *should* be the thread root,
		# but we can never trust clients to do the right thing
		my $ref = $refs->[0];
		$tid = resolve_mid_to_tid($self, $ref);
		merge_threads($self, $tid, $old_tid) if defined $old_tid;

		# the rest of the refs should point to this tid:
		foreach my $i (1..$#$refs) {
			$ref = $refs->[$i];
			my $ptid = resolve_mid_to_tid($self, $ref);
			merge_threads($self, $tid, $ptid);
		}
	} else {
		$tid = $old_tid // next_tid($self);
	}
	$tid;
}

# normalize subjects so they are suitable as pathnames for URLs
# XXX: consider for removal
sub subject_path ($) {
	my ($subj) = @_;
	$subj = subject_normalized($subj);
	$subj =~ s![^a-zA-Z0-9_\.~/\-]+!_!g;
	lc($subj);
}

sub ddd_for ($) {
	my ($smsg) = @_;
	my $dd = $smsg->to_doc_data;
	utf8::encode($dd);
	compress($dd);
}

sub add_overview {
	my ($self, $eml, $smsg) = @_;
	$smsg->{lines} = $eml->body_raw =~ tr!\n!\n!;
	my $mids = mids_for_index($eml);
	my $refs = $smsg->parse_references($eml, $mids);
	$mids->[0] //= do {
		$smsg->{mid} //= '';
		$eml->{-lei_fake_mid};
	};
	my $subj = $smsg->{subject};
	my $xpath;
	if ($subj ne '') {
		$xpath = subject_path($subj);
		$xpath = id_compress($xpath);
	}
	add_over($self, $smsg, $mids, $refs, $xpath, ddd_for($smsg));
}

sub _add_over {
	my ($self, $smsg, $mid, $refs, $old_tid, $v) = @_;
	my $cur_tid = $smsg->{tid};
	my $n = $smsg->{num};
	die "num must not be zero for $mid" if !$n;
	my $cur_valid = $cur_tid > $self->{min_tid};

	if ($n > 0) { # regular mail
		if ($cur_valid) {
			$$old_tid //= $cur_tid;
			merge_threads($self, $$old_tid, $cur_tid);
		} else {
			$$old_tid //= next_tid($self);
		}
	} elsif ($n < 0) { # ghost
		$$old_tid //= $cur_valid ? $cur_tid : next_tid($self);
		$$old_tid = link_refs($self, $refs, $$old_tid);
		delete_by_num($self, $n);
		$$v++;
	}
	1;
}

sub add_over {
	my ($self, $smsg, $mids, $refs, $xpath, $ddd) = @_;
	my $old_tid;
	my $vivified = 0;
	my $num = $smsg->{num};

	begin_lazy($self);
	delete_by_num($self, $num, \$old_tid);
	$old_tid = undef if ($old_tid // 0) <= $self->{min_tid};
	foreach my $mid (@$mids) {
		my $v = 0;
		each_by_mid($self, $mid, ['tid'], \&_add_over,
				$mid, $refs, \$old_tid, \$v);
		$v > 1 and warn "BUG: vivified multiple ($v) ghosts for $mid\n";
		$vivified += $v;
	}
	$smsg->{tid} = $vivified ? $old_tid : link_refs($self, $refs, $old_tid);
	$smsg->{sid} = sid($self, $xpath);
	my $dbh = $self->{dbh};
	my $sth = $dbh->prepare_cached(<<'');
INSERT INTO over (num, tid, sid, ts, ds, ddd)
VALUES (?,?,?,?,?,?)

	my $nc = 1;
	$sth->bind_param($nc, $num);
	$sth->bind_param(++$nc, $smsg->{$_}) for (qw(tid sid ts ds));
	$sth->bind_param(++$nc, $ddd, SQL_BLOB);
	$sth->execute;
	$sth = $dbh->prepare_cached(<<'');
INSERT INTO id2num (id, num) VALUES (?,?)

	foreach my $mid (@$mids) {
		my $id = mid2id($self, $mid);
		$sth->execute($id, $num);
	}
}

sub _remove_oid {
	my ($self, $smsg, $oid, $removed) = @_;
	if (!defined($oid) || $smsg->{blob} eq $oid) {
		delete_by_num($self, $smsg->{num});
		push @$removed, $smsg->{num};
	}
	1;
}

# returns number of removed messages in scalar context,
# array of removed article numbers in array context.
# $oid may be undef to match only on $mid
sub remove_oid {
	my ($self, $oid, $mid) = @_;
	my $removed = [];
	begin_lazy($self);
	each_by_mid($self, $mid, ['ddd'], \&_remove_oid, $oid, $removed);
	@$removed;
}

sub _num_mid0_for_oid {
	my ($self, $smsg, $oid, $res) = @_;
	my $blob = $smsg->{blob};
	return 1 if (!defined($blob) || $blob ne $oid); # continue;
	@$res = ($smsg->{num}, $smsg->{mid});
	0; # done
}

sub num_mid0_for_oid {
	my ($self, $oid, $mid) = @_;
	my $res = [];
	begin_lazy($self);
	each_by_mid($self, $mid, ['ddd'], \&_num_mid0_for_oid, $oid, $res);
	@$res, # ($num, $mid0);
}

sub create_tables {
	my ($dbh) = @_;

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS over (
	num INTEGER PRIMARY KEY NOT NULL, /* NNTP article number == IMAP UID */
	tid INTEGER NOT NULL, /* THREADID (IMAP REFERENCES threading, JMAP) */
	sid INTEGER, /* Subject ID (IMAP ORDEREDSUBJECT "threading") */
	ts INTEGER, /* IMAP INTERNALDATE (Received: header, git commit time) */
	ds INTEGER, /* RFC-2822 sent Date: header, git author time */
	ddd VARBINARY /* doc-data-deflated (->to_doc_data, ->load_from_data) */
)

	$dbh->do('CREATE INDEX IF NOT EXISTS idx_tid ON over (tid)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_sid ON over (sid)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_ts ON over (ts)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_ds ON over (ds)');

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS counter (
	key VARCHAR(8) PRIMARY KEY NOT NULL,
	val INTEGER DEFAULT 0,
	UNIQUE (key)
)

	$dbh->do("INSERT OR IGNORE INTO counter (key) VALUES ('thread')");
	$dbh->do("INSERT OR IGNORE INTO counter (key) VALUES ('ghost')");

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS subject (
	sid INTEGER PRIMARY KEY AUTOINCREMENT,
	path VARCHAR(40) NOT NULL, /* SHA-1 of normalized subject */
	UNIQUE (path)
)

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS id2num (
	id INTEGER NOT NULL, /* <=> msgid.id */
	num INTEGER NOT NULL,
	UNIQUE (id, num)
)

	# performance critical:
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_inum ON id2num (num)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_id ON id2num (id)');

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS msgid (
	id INTEGER PRIMARY KEY AUTOINCREMENT, /* <=> id2num.id */
	mid VARCHAR(244) NOT NULL,
	UNIQUE (mid)
)

}

sub commit_lazy {
	my ($self) = @_;
	delete $self->{txn} or return;
	$self->{dbh}->commit;
}

sub begin_lazy {
	my ($self) = @_;
	return if $self->{txn};
	my $dbh = $self->dbh or return;
	$dbh->begin_work;
	# $dbh->{Profile} = 2;
	$self->{txn} = 1;
}

sub rollback_lazy {
	my ($self) = @_;
	delete $self->{txn} or return;
	$self->{dbh}->rollback;
}

sub dbh_close {
	my ($self) = @_;
	die "in transaction" if $self->{txn};
	$self->SUPER::dbh_close;
}

sub create {
	my ($self) = @_;
	my $fn = $self->{filename} // do {
		croak('BUG: no {filename}') unless $self->{dbh};
		return;
	};
	unless (-r $fn) {
		require File::Path;
		my ($dir) = ($fn =~ m!(.*?/)[^/]+\z!);
		File::Path::mkpath($dir);
	}
	# create the DB:
	PublicInbox::Over::dbh($self);
	$self->dbh_close;
}

sub rethread_prepare {
	my ($self, $opt) = @_;
	return unless $opt->{rethread};
	begin_lazy($self);
	my $min = $self->{min_tid} = get_counter($self->{dbh}, 'thread') // 0;
	my $pr = $opt->{-progress};
	$pr->("rethread min THREADID ".($min + 1)."\n") if $pr && $min;
}

sub rethread_done {
	my ($self, $opt) = @_;
	return unless $opt->{rethread} && $self->{txn};
	defined(my $min = $self->{min_tid}) or croak('BUG: no min_tid');
	my $dbh = $self->{dbh} or croak('BUG: no dbh');
	my $rows = $dbh->selectall_arrayref(<<'', { Slice => {} }, $min);
SELECT num,tid FROM over WHERE num < 0 AND tid < ?

	my $show_id = $dbh->prepare('SELECT id FROM id2num WHERE num = ?');
	my $show_mid = $dbh->prepare('SELECT mid FROM msgid WHERE id = ?');
	my $pr = $opt->{-progress};
	my $total = 0;
	for my $r (@$rows) {
		my $exp = 0;
		$show_id->execute($r->{num});
		while (defined(my $id = $show_id->fetchrow_array)) {
			++$exp;
			$show_mid->execute($id);
			my $mid = $show_mid->fetchrow_array;
			if (!defined($mid)) {
				warn <<EOF;
E: ghost NUM=$r->{num} ID=$id THREADID=$r->{tid} has no Message-ID
EOF
				next;
			}
			$pr->(<<EOM) if $pr;
I: ghost $r->{num} <$mid> THREADID=$r->{tid} culled
EOM
		}
		delete_by_num($self, $r->{num});
	}
	$pr->("I: rethread culled $total ghosts\n") if $pr && $total;
}

# used for cross-inbox search
sub eidx_prep ($) {
	my ($self) = @_;
	$self->{-eidx_prep} //= do {
		my $dbh = $self->dbh;
		$dbh->do(<<'');
INSERT OR IGNORE INTO counter (key) VALUES ('eidx_docid')

		$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS inboxes (
	ibx_id INTEGER PRIMARY KEY AUTOINCREMENT,
	eidx_key VARCHAR(255) NOT NULL, /* {newsgroup} // {inboxdir} */
	UNIQUE (eidx_key)
)

		$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS xref3 (
	docid INTEGER NOT NULL, /* <=> over.num */
	ibx_id INTEGER NOT NULL, /* <=> inboxes.ibx_id */
	xnum INTEGER NOT NULL, /* NNTP article number in ibx */
	oidbin VARBINARY NOT NULL, /* 20-byte SHA-1 or 32-byte SHA-256 */
	UNIQUE (docid, ibx_id, xnum, oidbin)
)

	$dbh->do('CREATE INDEX IF NOT EXISTS idx_docid ON xref3 (docid)');

	# performance critical, this is not UNIQUE since we may need to
	# tolerate some old bugs from indexing mirrors
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_nntp ON '.
		'xref3 (oidbin,xnum,ibx_id)');

		$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS eidx_meta (
	key VARCHAR(255) PRIMARY KEY,
	val VARCHAR(255) NOT NULL
)

		# A queue of current docids which need reindexing.
		# eidxq persists across aborted -extindex invocations
		# Currently used for "-extindex --reindex" for Xapian
		# data, but may be used in more places down the line.
		$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS eidxq (docid INTEGER PRIMARY KEY NOT NULL)

		1;
	};
}

sub eidx_meta { # requires transaction
	my ($self, $key, $val) = @_;

	my $sql = 'SELECT val FROM eidx_meta WHERE key = ? LIMIT 1';
	my $dbh = $self->{dbh};
	defined($val) or return $dbh->selectrow_array($sql, undef, $key);

	my $prev = $dbh->selectrow_array($sql, undef, $key);
	if (defined $prev) {
		$sql = 'UPDATE eidx_meta SET val = ? WHERE key = ?';
		$dbh->do($sql, undef, $val, $key);
	} else {
		$sql = 'INSERT INTO eidx_meta (key,val) VALUES (?,?)';
		$dbh->do($sql, undef, $key, $val);
	}
	$prev;
}

sub eidx_max {
	my ($self) = @_;
	get_counter($self->{dbh}, 'eidx_docid');
}

sub add_xref3 {
	my ($self, $docid, $xnum, $oidhex, $eidx_key) = @_;
	begin_lazy($self);
	my $ibx_id = ibx_id($self, $eidx_key);
	my $oidbin = pack('H*', $oidhex);
	my $sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR IGNORE INTO xref3 (docid, ibx_id, xnum, oidbin) VALUES (?, ?, ?, ?)

	$sth->bind_param(1, $docid);
	$sth->bind_param(2, $ibx_id);
	$sth->bind_param(3, $xnum);
	$sth->bind_param(4, $oidbin, SQL_BLOB);
	$sth->execute;
}

# returns remaining reference count to $docid
sub remove_xref3 {
	my ($self, $docid, $oidhex, $eidx_key, $rm_eidx_info) = @_;
	begin_lazy($self);
	my $oidbin = pack('H*', $oidhex);
	my ($sth, $ibx_id);
	if (defined $eidx_key) {
		$ibx_id = ibx_id($self, $eidx_key);
		$sth = $self->{dbh}->prepare_cached(<<'');
DELETE FROM xref3 WHERE docid = ? AND ibx_id = ? AND oidbin = ?

		$sth->bind_param(1, $docid);
		$sth->bind_param(2, $ibx_id);
		$sth->bind_param(3, $oidbin, SQL_BLOB);
	} else {
		$sth = $self->{dbh}->prepare_cached(<<'');
DELETE FROM xref3 WHERE docid = ? AND oidbin = ?

		$sth->bind_param(1, $docid);
		$sth->bind_param(2, $oidbin, SQL_BLOB);
	}
	$sth->execute;
	$sth = $self->{dbh}->prepare_cached(<<'', undef, 1);
SELECT COUNT(*) FROM xref3 WHERE docid = ?

	$sth->execute($docid);
	my $nr = $sth->fetchrow_array;
	if ($nr == 0) {
		delete_by_num($self, $docid);
	} elsif (defined($ibx_id) && $rm_eidx_info) {
		# if deduplication rules in ContentHash change, it's
		# possible a docid can have multiple rows with the
		# same ibx_id.  This governs whether or not we call
		# ->remove_eidx_info in ExtSearchIdx.
		$sth = $self->{dbh}->prepare_cached(<<'', undef, 1);
SELECT COUNT(*) FROM xref3 WHERE docid = ? AND ibx_id = ?

		$sth->execute($docid, $ibx_id);
		my $count = $sth->fetchrow_array;
		$$rm_eidx_info = ($count == 0);
	}
	$nr;
}

# for when an xref3 goes missing, this does NOT update {ts}
sub update_blob {
	my ($self, $smsg, $oidhex) = @_;
	my $sth = $self->{dbh}->prepare(<<'');
UPDATE over SET ddd = ? WHERE num = ?

	$smsg->{blob} = $oidhex;
	$sth->bind_param(1, ddd_for($smsg), SQL_BLOB);
	$sth->bind_param(2, $smsg->{num});
	$sth->execute;
}

sub merge_xref3 { # used for "-extindex --dedupe"
	my ($self, $keep_docid, $drop_docid, $oidhex) = @_;
	my $oidbin = pack('H*', $oidhex);
	my $sth = $self->{dbh}->prepare_cached(<<'');
UPDATE OR IGNORE xref3 SET docid = ? WHERE docid = ? AND oidbin = ?

	$sth->bind_param(1, $keep_docid);
	$sth->bind_param(2, $drop_docid);
	$sth->bind_param(3, $oidbin, SQL_BLOB);
	$sth->execute;

	# drop anything that conflicted
	$sth = $self->{dbh}->prepare_cached(<<'');
DELETE FROM xref3 WHERE docid = ? AND oidbin = ?

	$sth->bind_param(1, $drop_docid);
	$sth->bind_param(2, $oidbin, SQL_BLOB);
	$sth->execute;
}

sub eidxq_add {
	my ($self, $docid) = @_;
	$self->dbh->prepare_cached(<<'')->execute($docid);
INSERT OR IGNORE INTO eidxq (docid) VALUES (?)

}

sub eidxq_del {
	my ($self, $docid) = @_;
	$self->dbh->prepare_cached(<<'')->execute($docid);
DELETE FROM eidxq WHERE docid = ?

}

# returns true if we're vivifying a message for lei/store that was
# previously external-metadata only
sub vivify_xvmd {
	my ($self, $smsg) = @_;
	my @docids = $self->blob_exists($smsg->{blob});
	my @vivify_xvmd;
	for my $id (@docids) {
		if (my $cur = $self->get_art($id)) {
			# already indexed if bytes > 0
			return if $cur->{bytes} > 0;
			push @vivify_xvmd, $id;
		} else {
			warn "W: $smsg->{blob} #$id gone (bug?)\n";
		}
	}
	$smsg->{-vivify_xvmd} = \@vivify_xvmd;
}

1;
