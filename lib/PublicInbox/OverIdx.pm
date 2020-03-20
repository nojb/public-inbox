# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for XOVER, OVER in NNTP, and feeds/homepage/threads in PSGI
# Unlike Msgmap, this is an _UNSTABLE_ cache which can be
# tweaked/updated over time and rebuilt.
#
# Ghost messages (messages which are only referenced in References/In-Reply-To)
# are denoted by a negative NNTP article number.
package PublicInbox::OverIdx;
use strict;
use warnings;
use base qw(PublicInbox::Over);
use IO::Handle;
use DBI qw(:sql_types); # SQL_BLOB
use PublicInbox::MID qw/id_compress mids_for_index references/;
use PublicInbox::Smsg qw(subject_normalized);
use PublicInbox::MsgTime qw(msg_timestamp msg_datestamp);
use Compress::Zlib qw(compress);
use PublicInbox::Search;

sub dbh_new {
	my ($self) = @_;
	my $dbh = $self->SUPER::dbh_new(1);
	$dbh->do('PRAGMA journal_mode = TRUNCATE');
	$dbh->do('PRAGMA cache_size = 80000');
	create_tables($dbh);
	$dbh;
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
	my ($self, $mid, $cols, $cb) = @_;
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
			$cb->(PublicInbox::Over::load_from_row($smsg)) or
				return;
		}
		return if $nr != $lim;
	}
}

# this will create a ghost as necessary
sub resolve_mid_to_tid {
	my ($self, $mid) = @_;
	my $tid;
	each_by_mid($self, $mid, ['tid'], sub {
		my ($smsg) = @_;
		my $cur_tid = $smsg->{tid};
		if (defined $tid) {
			merge_threads($self, $tid, $cur_tid);
		} else {
			$tid = $cur_tid;
		}
		1;
	});
	defined $tid ? $tid : create_ghost($self, $mid);
}

sub create_ghost {
	my ($self, $mid) = @_;
	my $id = $self->mid2id($mid);
	my $num = $self->next_ghost_num;
	$num < 0 or die "ghost num is non-negative: $num\n";
	my $tid = $self->next_tid;
	my $dbh = $self->{dbh};
	$dbh->prepare_cached(<<'')->execute($num, $tid);
INSERT INTO over (num, tid) VALUES (?,?)

	$dbh->prepare_cached(<<'')->execute($id, $num);
INSERT INTO id2num (id, num) VALUES (?,?)

	$tid;
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
		$tid = defined $old_tid ? $old_tid : $self->next_tid;
	}
	$tid;
}

sub parse_references ($$$) {
	my ($smsg, $mid0, $mids) = @_;
	my $mime = $smsg->{mime};
	my $hdr = $mime->header_obj;
	my $refs = references($hdr);
	push(@$refs, @$mids) if scalar(@$mids) > 1;
	return $refs if scalar(@$refs) == 0;

	# prevent circular references here:
	my %seen = ( $mid0 => 1 );
	my @keep;
	foreach my $ref (@$refs) {
		if (length($ref) > PublicInbox::MID::MAX_MID_SIZE) {
			warn "References: <$ref> too long, ignoring\n";
			next;
		}
		push(@keep, $ref) unless $seen{$ref}++;
	}
	$smsg->{references} = '<'.join('> <', @keep).'>' if @keep;
	\@keep;
}

# normalize subjects so they are suitable as pathnames for URLs
# XXX: consider for removal
sub subject_path ($) {
	my ($subj) = @_;
	$subj = subject_normalized($subj);
	$subj =~ s![^a-zA-Z0-9_\.~/\-]+!_!g;
	lc($subj);
}

sub add_overview {
	my ($self, $mime, $bytes, $num, $oid, $mid0, $times) = @_;
	my $lines = $mime->body_raw =~ tr!\n!\n!;
	my $smsg = bless {
		mime => $mime,
		mid => $mid0,
		bytes => $bytes,
		lines => $lines,
		blob => $oid,
	}, 'PublicInbox::Smsg';
	my $hdr = $mime->header_obj;
	my $mids = mids_for_index($hdr);
	my $refs = parse_references($smsg, $mid0, $mids);
	my $subj = $smsg->subject;
	my $xpath;
	if ($subj ne '') {
		$xpath = subject_path($subj);
		$xpath = id_compress($xpath);
	}
	my $dd = $smsg->to_doc_data($oid, $mid0);
	utf8::encode($dd);
	$dd = compress($dd);
	my $ds = msg_timestamp($hdr, $times->{autime});
	my $ts = msg_datestamp($hdr, $times->{cotime});
	my $values = [ $ts, $ds, $num, $mids, $refs, $xpath, $dd ];
	add_over($self, $values);
}

sub add_over {
	my ($self, $values) = @_;
	my ($ts, $ds, $num, $mids, $refs, $xpath, $ddd) = @$values;
	my $old_tid;
	my $vivified = 0;

	$self->begin_lazy;
	$self->delete_by_num($num, \$old_tid);
	foreach my $mid (@$mids) {
		my $v = 0;
		each_by_mid($self, $mid, ['tid'], sub {
			my ($cur) = @_;
			my $cur_tid = $cur->{tid};
			my $n = $cur->{num};
			die "num must not be zero for $mid" if !$n;
			$old_tid = $cur_tid unless defined $old_tid;
			if ($n > 0) { # regular mail
				merge_threads($self, $old_tid, $cur_tid);
			} elsif ($n < 0) { # ghost
				link_refs($self, $refs, $old_tid);
				$self->delete_by_num($n);
				$v++;
			}
			1;
		});
		$v > 1 and warn "BUG: vivified multiple ($v) ghosts for $mid\n";
		$vivified += $v;
	}
	my $tid = $vivified ? $old_tid : link_refs($self, $refs, $old_tid);
	my $sid = $self->sid($xpath);
	my $dbh = $self->{dbh};
	my $sth = $dbh->prepare_cached(<<'');
INSERT INTO over (num, tid, sid, ts, ds, ddd)
VALUES (?,?,?,?,?,?)

	my $n = 0;
	my @v = ($num, $tid, $sid, $ts, $ds);
	foreach (@v) { $sth->bind_param(++$n, $_) }
	$sth->bind_param(++$n, $ddd, SQL_BLOB);
	$sth->execute;
	$sth = $dbh->prepare_cached(<<'');
INSERT INTO id2num (id, num) VALUES (?,?)

	foreach my $mid (@$mids) {
		my $id = $self->mid2id($mid);
		$sth->execute($id, $num);
	}
}

# returns number of removed messages
# $oid may be undef to match only on $mid
sub remove_oid {
	my ($self, $oid, $mid) = @_;
	my $nr = 0;
	$self->begin_lazy;
	each_by_mid($self, $mid, ['ddd'], sub {
		my ($smsg) = @_;
		if (!defined($oid) || $smsg->{blob} eq $oid) {
			$self->delete_by_num($smsg->{num});
			$nr++;
		}
		1;
	});
	$nr;
}

sub num_mid0_for_oid {
	my ($self, $oid, $mid) = @_;
	my ($num, $mid0);
	$self->begin_lazy;
	each_by_mid($self, $mid, ['ddd'], sub {
		my ($smsg) = @_;
		my $blob = $smsg->{blob};
		return 1 if (!defined($blob) || $blob ne $oid); # continue;
		($num, $mid0) = ($smsg->{num}, $smsg->{mid});
		0; # done
	});
	($num, $mid0);
}

sub create_tables {
	my ($dbh) = @_;

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS over (
	num INTEGER NOT NULL,
	tid INTEGER NOT NULL,
	sid INTEGER,
	ts INTEGER,
	ds INTEGER,
	ddd VARBINARY, /* doc-data-deflated */
	UNIQUE (num)
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
	path VARCHAR(40) NOT NULL,
	UNIQUE (path)
)

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS id2num (
	id INTEGER NOT NULL,
	num INTEGER NOT NULL,
	UNIQUE (id, num)
)

	# performance critical:
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_inum ON id2num (num)');
	$dbh->do('CREATE INDEX IF NOT EXISTS idx_id ON id2num (id)');

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS msgid (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
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
	my $dbh = $self->connect or return;
	$dbh->begin_work;
	# $dbh->{Profile} = 2;
	$self->{txn} = 1;
}

sub rollback_lazy {
	my ($self) = @_;
	delete $self->{txn} or return;
	$self->{dbh}->rollback;
}

sub disconnect {
	my ($self) = @_;
	die "in transaction" if $self->{txn};
	$self->{dbh} = undef;
}

sub create {
	my ($self) = @_;
	unless (-r $self->{filename}) {
		require File::Path;
		require File::Basename;
		File::Path::mkpath(File::Basename::dirname($self->{filename}));
	}
	# create the DB:
	PublicInbox::Over::connect($self);
	$self->disconnect;
}

1;
