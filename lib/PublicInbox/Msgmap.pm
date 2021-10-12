# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# bidirectional Message-ID <-> Article Number mapping for the NNTP
# and web interfaces.  This is required for implementing stable article
# numbers for NNTP and allows prefix lookups for partial Message-IDs
# in case URLs get truncated from copy-n-paste errors by users.
#
# This is maintained by ::SearchIdx (v1) and ::V2Writable (v2)
package PublicInbox::Msgmap;
use strict;
use v5.10.1;
use DBI;
use DBD::SQLite;
use PublicInbox::Over;
use PublicInbox::Spawn;
use Scalar::Util qw(blessed);

sub new_file {
	my ($class, $ibx, $rw) = @_;
	my $f;
	if (blessed($ibx)) {
		$f = $ibx->mm_file;
		$rw = 2 if $rw && $ibx->{-no_fsync};
	} else {
		$f = $ibx;
	}
	return if !$rw && !-r $f;

	my $self = bless { filename => $f }, $class;
	my $dbh = $self->{dbh} = PublicInbox::Over::dbh_new($self, $rw);
	if ($rw) {
		$dbh->begin_work;
		create_tables($dbh);
		unless ($self->created_at) {
			my $t;

			if (blessed($ibx) &&
				-f "$ibx->{inboxdir}/inbox.config.example") {
				$t = (stat(_))[9]; # mtime set by "curl -R"
			}
			$self->created_at($t // time);
		}
		$self->num_highwater(max($self));
		$dbh->commit;
	}
	$self;
}

# used to keep track of used numeric mappings for v2 reindex
sub tmp_clone {
	my ($self, $dir) = @_;
	require File::Temp;
	my $tmp = "mm_tmp-$$-XXXX";
	my ($fh, $fn) = File::Temp::tempfile($tmp, EXLOCK => 0, DIR => $dir);
	PublicInbox::Spawn::nodatacow_fd(fileno($fh));
	$self->{dbh}->sqlite_backup_to_file($fn);
	$tmp = ref($self)->new_file($fn, 2);
	$tmp->{dbh}->do('PRAGMA journal_mode = MEMORY');
	$tmp->{pid} = $$;
	$tmp;
}

# n.b. invoked directly by scripts/xhdr-num2mid
sub meta_accessor {
	my ($self, $key, $value) = @_;

	my $sql = 'SELECT val FROM meta WHERE key = ? LIMIT 1';
	my $prev = $self->{dbh}->selectrow_array($sql, undef, $key);
	$value // return $prev;

	if (defined $prev) {
		$sql = 'UPDATE meta SET val = ? WHERE key = ?';
		$self->{dbh}->do($sql, undef, $value, $key);
	} else {
		$sql = 'INSERT INTO meta (key,val) VALUES (?,?)';
		$self->{dbh}->do($sql, undef, $key, $value);
	}
	$prev;
}

sub last_commit {
	my ($self, $commit) = @_;
	$self->meta_accessor('last_commit', $commit);
}

# v2 uses this to keep track of how up-to-date Xapian is
# old versions may be automatically GC'ed away in the future,
# but it's a trivial amount of storage.
sub last_commit_xap {
	my ($self, $version, $i, $commit) = @_;
	$self->meta_accessor("last_xap$version-$i", $commit);
}

# this is the UIDVALIDITY for IMAP (cf. RFC 3501 sec 2.3.1.1. item 3)
sub created_at {
	my ($self, $second) = @_;
	$self->meta_accessor('created_at', $second);
}

sub num_highwater {
	my ($self, $num) = @_;
	my $high = $self->{num_highwater} ||=
	    $self->meta_accessor('num_highwater');
	if (defined($num) && (!defined($high) || ($num > $high))) {
		$self->{num_highwater} = $num;
		$self->meta_accessor('num_highwater', $num);
	}
	$self->{num_highwater};
}

sub mid_insert {
	my ($self, $mid) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<'');
INSERT INTO msgmap (mid) VALUES (?)

	return unless eval { $sth->execute($mid) };
	my $num = $self->{dbh}->last_insert_id(undef, undef, 'msgmap', 'num');
	$self->num_highwater($num) if defined($num);
	$num;
}

sub mid_for {
	my ($self, $num) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<"", undef, 1);
SELECT mid FROM msgmap WHERE num = ? LIMIT 1

	$sth->execute($num);
	$sth->fetchrow_array;
}

sub num_for {
	my ($self, $mid) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<"", undef, 1);
SELECT num FROM msgmap WHERE mid = ? LIMIT 1

	$sth->execute($mid);
	$sth->fetchrow_array;
}

sub max {
	my $sth = $_[0]->{dbh}->prepare_cached('SELECT MAX(num) FROM msgmap',
						undef, 1);
	$sth->execute;
	$sth->fetchrow_array // 0;
}

sub minmax {
	# breaking MIN and MAX into separate queries speeds up from 250ms
	# to around 700us with 2.7million messages.
	my $sth = $_[0]->{dbh}->prepare_cached('SELECT MIN(num) FROM msgmap',
						undef, 1);
	$sth->execute;
	($sth->fetchrow_array // 0, max($_[0]));
}

sub mid_delete {
	my ($self, $mid) = @_;
	$self->{dbh}->do('DELETE FROM msgmap WHERE mid = ?', undef, $mid);
}

sub num_delete {
	my ($self, $num) = @_;
	$self->{dbh}->do('DELETE FROM msgmap WHERE num = ?', undef, $num);
}

sub create_tables {
	my ($dbh) = @_;

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS msgmap (
	num INTEGER PRIMARY KEY AUTOINCREMENT,
	mid VARCHAR(1000) NOT NULL,
	UNIQUE (mid)
)

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS meta (
	key VARCHAR(32) PRIMARY KEY,
	val VARCHAR(255) NOT NULL
)

}

sub msg_range {
	my ($self, $beg, $end, $cols) = @_;
	$cols //= 'num,mid';
	my $attr = { Columns => [] };
	my $mids = $self->{dbh}->selectall_arrayref(<<"", $attr, $$beg, $end);
SELECT $cols FROM msgmap WHERE num >= ? AND num <= ?
ORDER BY num ASC LIMIT 1000

	$$beg = $mids->[-1]->[0] + 1 if @$mids;
	$mids
}

# only used for mapping external serial numbers (e.g. articles from gmane)
# see scripts/xhdr-num2mid or PublicInbox::Filter::RubyLang for usage
sub mid_set {
	my ($self, $num, $mid) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<"");
INSERT OR IGNORE INTO msgmap (num,mid) VALUES (?,?)

	my $result = $sth->execute($num, $mid);
	$self->num_highwater($num) if (defined($result) && $result == 1);
	$result;
}

sub DESTROY {
	my ($self) = @_;
	my $dbh = $self->{dbh} or return;
	if (($self->{pid} // 0) == $$) {
		my $f = $dbh->sqlite_db_filename;
		unlink $f or warn "failed to unlink $f: $!\n";
	}
}

sub atfork_parent {
	my ($self) = @_;
	$self->{pid} or die 'BUG: not a temporary clone';
	$self->{dbh} and die 'BUG: tmp_clone dbh not prepared for parent';
	defined($self->{filename}) or die 'BUG: {filename} not defined';
	$self->{dbh} = PublicInbox::Over::dbh_new($self, 2);
	$self->{dbh}->do('PRAGMA journal_mode = MEMORY');
}

sub atfork_prepare {
	my ($self) = @_;
	my $pid = $self->{pid} or die 'BUG: not a temporary clone';
	$pid == $$ or die "BUG: atfork_prepare not called by $pid";
	my $dbh = $self->{dbh} or die 'BUG: temporary clone not open';

	# must clobber prepared statements
	%$self = (filename => $dbh->sqlite_db_filename, pid => $pid);
}

sub skip_artnum {
	my ($self, $skip_artnum) = @_;
	return meta_accessor($self, 'skip_artnum') if !defined($skip_artnum);

	my $cur = num_highwater($self) // 0;
	if ($skip_artnum < $cur) {
		die "E: current article number $cur ",
			"exceeds --skip-artnum=$skip_artnum\n";
	} else {
		my $ok;
		for (1..10) {
			my $mid = 'skip'.rand.'@'.rand.'.example.com';
			$ok = mid_set($self, $skip_artnum, $mid);
			if ($ok) {
				mid_delete($self, $mid);
				last;
			}
		}
		$ok or die '--skip-artnum failed';

		# in the future, the indexer may use this value for
		# new messages in old epochs
		meta_accessor($self, 'skip_artnum', $skip_artnum);
	}
}

sub check_inodes {
	my ($self) = @_;
	$self->{dbh} // return;
	my $rw = !$self->{dbh}->{ReadOnly};
	PublicInbox::Over::check_inodes($self);
	$self->{dbh} //= PublicInbox::Over::dbh_new($self, !$rw);
}

1;
