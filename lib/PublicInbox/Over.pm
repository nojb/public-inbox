# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for XOVER, OVER in NNTP, and feeds/homepage/threads in PSGI
# Unlike Msgmap, this is an _UNSTABLE_ database which can be
# tweaked/updated over time and rebuilt.
package PublicInbox::Over;
use strict;
use v5.10.1;
use DBI qw(:sql_types); # SQL_BLOB
use DBD::SQLite;
use PublicInbox::Smsg;
use Compress::Zlib qw(uncompress);
use constant DEFAULT_LIMIT => 1000;

sub dbh_new {
	my ($self, $rw) = @_;
	my $f = delete $self->{filename};
	if (!-s $f) { # SQLite defaults mode to 0644, we want 0666
		if ($rw) {
			require PublicInbox::Syscall;
			my ($dir) = ($f =~ m!(.+)/[^/]+\z!);
			PublicInbox::Syscall::nodatacow_dir($dir);
			open my $fh, '+>>', $f or die "failed to open $f: $!";
		} else {
			$self->{filename} = $f; # die on stat() below:
		}
	}
	my (@st, $st, $dbh);
	my $tries = 0;
	do {
		@st = stat($f) or die "failed to stat $f: $!";
		$st = pack('dd', $st[0], $st[1]); # 0: dev, 1: inode
		$dbh = DBI->connect("dbi:SQLite:dbname=$f",'','', {
			AutoCommit => 1,
			RaiseError => 1,
			PrintError => 0,
			ReadOnly => !$rw,
			sqlite_use_immediate_transaction => 1,
		});
		$self->{st} = $st;
		@st = stat($f) or die "failed to stat $f: $!";
		$st = pack('dd', $st[0], $st[1]);
	} while ($st ne $self->{st} && $tries++ < 3);
	warn "W: $f: .st_dev, .st_ino unstable\n" if $st ne $self->{st};

	if ($rw) {
		# TRUNCATE reduces I/O compared to the default (DELETE).
		#
		# Do not use WAL by default since we expect the case
		# where any users may read via read-only daemons
		# (-httpd/-imapd/-nntpd); but only a single user has
		# write permissions for -watch/-mda.
		#
		# Read-only WAL support in SQLite 3.22.0 (2018-01-22)
		# doesn't do what we need: it is only intended for
		# immutable read-only media (e.g. CD-ROM) and not
		# usable for our use case described above.
		#
		# If an admin is willing to give read-only daemons R/W
		# permissions; they can enable WAL manually and we will
		# respect that by not clobbering it.
		my $jm = $dbh->selectrow_array('PRAGMA journal_mode');
		$dbh->do('PRAGMA journal_mode = TRUNCATE') if $jm ne 'wal';

		$dbh->do('PRAGMA synchronous = OFF') if $rw > 1;
	}
	$dbh;
}

sub new {
	my ($class, $f) = @_;
	bless { filename => $f }, $class;
}

sub dbh_close {
	my ($self) = @_;
	if (my $dbh = delete $self->{dbh}) {
		delete $self->{-get_art};
		$self->{filename} = $dbh->sqlite_db_filename;
	}
}

sub dbh ($) { $_[0]->{dbh} //= $_[0]->dbh_new } # dbh_new may be subclassed

sub load_from_row ($;$) {
	my ($smsg, $cull) = @_;
	bless $smsg, 'PublicInbox::Smsg';
	if (defined(my $data = delete $smsg->{ddd})) {
		$data = uncompress($data);
		PublicInbox::Smsg::load_from_data($smsg, $data);

		# saves over 600K for 1000+ message threads
		PublicInbox::Smsg::psgi_cull($smsg) if $cull;
	}
	$smsg
}

sub do_get {
	my ($self, $sql, $opts, @args) = @_;
	my $lim = (($opts->{limit} || 0) + 0) || DEFAULT_LIMIT;
	$sql .= "LIMIT $lim";
	my $msgs = dbh($self)->selectall_arrayref($sql, { Slice => {} }, @args);
	my $cull = $opts->{cull};
	load_from_row($_, $cull) for @$msgs;
	$msgs
}

sub query_xover {
	my ($self, $beg, $end, $opt) = @_;
	do_get($self, <<'', $opt, $beg, $end);
SELECT num,ts,ds,ddd FROM over WHERE num >= ? AND num <= ?
ORDER BY num ASC

}

sub query_ts {
	my ($self, $ts, $prev) = @_;
	do_get($self, <<'', {}, $ts, $prev);
SELECT num,ddd FROM over WHERE ts >= ? AND num > ?
ORDER BY num ASC

}

sub get_all {
	my $self = shift;
	my $nr = scalar(@_) or return [];
	my $in = '?' . (',?' x ($nr - 1));
	do_get($self, <<"", { cull => 1, limit => $nr }, @_);
SELECT num,ts,ds,ddd FROM over WHERE num IN ($in)

}

sub nothing () { wantarray ? (0, []) : [] };

sub get_thread {
	my ($self, $mid, $prev) = @_;
	my $dbh = dbh($self);
	my $opts = { cull => 1 };

	my $id = $dbh->selectrow_array(<<'', undef, $mid);
SELECT id FROM msgid WHERE mid = ? LIMIT 1

	defined $id or return nothing;

	my $num = $dbh->selectrow_array(<<'', undef, $id);
SELECT num FROM id2num WHERE id = ? AND num > 0
ORDER BY num ASC LIMIT 1

	defined $num or return nothing;

	my ($tid, $sid) = $dbh->selectrow_array(<<'', undef, $num);
SELECT tid,sid FROM over WHERE num = ? LIMIT 1

	defined $tid or return nothing; # $sid may be undef

	my $cond_all = '(tid = ? OR sid = ?) AND num > ?';
	my $sort_col = 'ds';
	$num = 0;
	if ($prev) { # mboxrd stream, only
		$num = $prev->{num} || 0;
		$sort_col = 'num';
	}

	my $cols = 'num,ts,ds,ddd';
	unless (wantarray) {
		return do_get($self, <<"", $opts, $tid, $sid, $num);
SELECT $cols FROM over WHERE $cond_all
ORDER BY $sort_col ASC

	}

	# HTML view always wants an array and never uses $prev,
	# but the mbox stream never wants an array and always has $prev
	die '$prev not supported with wantarray' if $prev;
	my $nr = $dbh->selectrow_array(<<"", undef, $tid, $sid, $num);
SELECT COUNT(num) FROM over WHERE $cond_all

	# giant thread, prioritize strict (tid) matches and throw
	# in the loose (sid) matches at the end
	my $msgs = do_get($self, <<"", $opts, $tid, $num);
SELECT $cols FROM over WHERE tid = ? AND num > ?
ORDER BY $sort_col ASC

	# do we have room for loose matches? get the most recent ones, first:
	my $lim = DEFAULT_LIMIT - scalar(@$msgs);
	if ($lim > 0) {
		$opts->{limit} = $lim;
		my $loose = do_get($self, <<"", $opts, $tid, $sid, $num);
SELECT $cols FROM over WHERE tid != ? AND sid = ? AND num > ?
ORDER BY $sort_col DESC

		# TODO separate strict and loose matches here once --reindex
		# is fixed to preserve `tid' properly
		push @$msgs, @$loose;
	}
	($nr, $msgs);
}

# strict `tid' matches, only, for thread-expanded mbox.gz search results
# and future CLI interface
# returns true if we have IDs, undef if not
sub expand_thread {
	my ($self, $ctx) = @_;
	my $dbh = dbh($self);
	do {
		defined(my $num = $ctx->{ids}->[0]) or return;
		my ($tid) = $dbh->selectrow_array(<<'', undef, $num);
SELECT tid FROM over WHERE num = ?

		if (defined($tid)) {
			my $sql = <<'';
SELECT num FROM over WHERE tid = ? AND num > ?
ORDER BY num ASC LIMIT 1000

			my $xids = $dbh->selectcol_arrayref($sql, undef, $tid,
							$ctx->{prev} // 0);
			if (scalar(@$xids)) {
				$ctx->{prev} = $xids->[-1];
				$ctx->{xids} = $xids;
				return 1; # success
			}
		}
		$ctx->{prev} = 0;
		shift @{$ctx->{ids}};
	} while (1);
}

sub recent {
	my ($self, $opts, $after, $before) = @_;
	my ($s, @v);
	if (defined($before)) {
		if (defined($after)) {
			$s = '+num > 0 AND ts >= ? AND ts <= ? ORDER BY ts DESC';
			@v = ($after, $before);
		} else {
			$s = '+num > 0 AND ts <= ? ORDER BY ts DESC';
			@v = ($before);
		}
	} else {
		if (defined($after)) {
			$s = '+num > 0 AND ts >= ? ORDER BY ts ASC';
			@v = ($after);
		} else {
			$s = '+num > 0 ORDER BY ts DESC';
		}
	}
	do_get($self, <<"", $opts, @v);
SELECT ts,ds,ddd FROM over WHERE $s

}

sub get_art {
	my ($self, $num) = @_;
	# caching $sth ourselves is faster than prepare_cached
	my $sth = $self->{-get_art} //= dbh($self)->prepare(<<'');
SELECT num,tid,ds,ts,ddd FROM over WHERE num = ? LIMIT 1

	$sth->execute($num);
	my $smsg = $sth->fetchrow_hashref;
	$smsg ? load_from_row($smsg) : undef;
}

sub get_xref3 {
	my ($self, $num, $raw) = @_;
	my $dbh = dbh($self);
	my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT ibx_id,xnum,oidbin FROM xref3 WHERE docid = ? ORDER BY ibx_id,xnum ASC

	$sth->execute($num);
	my $rows = $sth->fetchall_arrayref;
	return $rows if $raw;
	my $eidx_key_sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT eidx_key FROM inboxes WHERE ibx_id = ?

	[ map {
		my $r = $_;
		$eidx_key_sth->execute($r->[0]);
		my $eidx_key = $eidx_key_sth->fetchrow_array;
		$eidx_key //= "missing://ibx_id=$r->[0]";
		"$eidx_key:$r->[1]:".unpack('H*', $r->[2]);
	} @$rows ];
}

sub next_by_mid {
	my ($self, $mid, $id, $prev) = @_;
	my $dbh = dbh($self);

	unless (defined $$id) {
		my $sth = $dbh->prepare_cached(<<'', undef, 1);
	SELECT id FROM msgid WHERE mid = ? LIMIT 1

		$sth->execute($mid);
		$$id = $sth->fetchrow_array;
		defined $$id or return;
	}
	my $sth = $dbh->prepare_cached(<<"", undef, 1);
SELECT num FROM id2num WHERE id = ? AND num > ?
ORDER BY num ASC LIMIT 1

	$$prev ||= 0;
	$sth->execute($$id, $$prev);
	my $num = $sth->fetchrow_array or return;
	$$prev = $num;
	get_art($self, $num);
}

# IMAP search, this is limited by callers to UID_SLICE size (50K)
sub uid_range {
	my ($self, $beg, $end, $sql) = @_;
	my $dbh = dbh($self);
	my $q = 'SELECT num FROM over WHERE num >= ? AND num <= ?';

	# This is read-only, anyways; but caller should verify it's
	# only sending \A[0-9]+\z for ds and ts column ranges
	$q .= $$sql if $sql;
	$q .= ' ORDER BY num ASC';
	$dbh->selectcol_arrayref($q, undef, $beg, $end);
}

sub max {
	my ($self) = @_;
	my $sth = dbh($self)->prepare_cached(<<'', undef, 1);
SELECT MAX(num) FROM over WHERE num > 0

	$sth->execute;
	$sth->fetchrow_array // 0;
}

sub imap_exists {
	my ($self, $uid_base, $uid_end) = @_;
	my $sth = dbh($self)->prepare_cached(<<'', undef, 1);
SELECT COUNT(num) FROM over WHERE num > ? AND num <= ?

	$sth->execute($uid_base, $uid_end);
	$sth->fetchrow_array;
}

sub check_inodes {
	my ($self) = @_;
	my $dbh = $self->{dbh} or return;
	my $f = $dbh->sqlite_db_filename;
	if (my @st = stat($f)) { # did st_dev, st_ino change?
		my $st = pack('dd', $st[0], $st[1]);

		# don't actually reopen, just let {dbh} be recreated later
		dbh_close($self) if $st ne ($self->{st} // $st);
	} else {
		warn "W: stat $f: $!\n";
	}
}

sub oidbin_exists {
	my ($self, $oidbin) = @_;
	if (wantarray) {
		my $sth = $self->dbh->prepare_cached(<<'', undef, 1);
SELECT docid FROM xref3 WHERE oidbin = ? ORDER BY docid ASC

		$sth->bind_param(1, $oidbin, SQL_BLOB);
		$sth->execute;
		my $tmp = $sth->fetchall_arrayref;
		map { $_->[0] } @$tmp;
	} else {
		my $sth = $self->dbh->prepare_cached(<<'', undef, 1);
SELECT COUNT(*) FROM xref3 WHERE oidbin = ?

		$sth->bind_param(1, $oidbin, SQL_BLOB);
		$sth->execute;
		$sth->fetchrow_array;
	}
}

sub blob_exists { oidbin_exists($_[0], pack('H*', $_[1])) }

# used by NNTP.pm
sub ids_after {
	my ($self, $num) = @_;
	my $ids = dbh($self)->selectcol_arrayref(<<'', undef, $$num);
SELECT num FROM over WHERE num > ?
ORDER BY num ASC LIMIT 1000

	$$num = $ids->[-1] if @$ids;
	$ids;
}

1;
