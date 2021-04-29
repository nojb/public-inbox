# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for maintaining synchronization between lei/store <=> Maildir|MH|IMAP|JMAP
package PublicInbox::LeiMailSync;
use strict;
use v5.10.1;
use DBI;

sub dbh_new {
	my ($self, $rw) = @_;
	my $f = $self->{filename};
	my $creat;
	if (!-f $f && $rw) {
		require PublicInbox::Spawn;
		open my $fh, '+>>', $f or die "failed to open $f: $!";
		PublicInbox::Spawn::nodatacow_fd(fileno($fh));
		$creat = 1;
	}
	my $dbh = DBI->connect("dbi:SQLite:dbname=$f",'','', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		ReadOnly => !$rw,
		sqlite_use_immediate_transaction => 1,
	});
	# no sqlite_unicode, here, all strings are binary
	create_tables($dbh) if $rw;
	$dbh->do('PRAGMA journal_mode = WAL') if $creat;
	$dbh->do('PRAGMA case_sensitive_like = ON');
	$dbh;
}

sub new {
	my ($cls, $f) = @_;
	bless { filename => $f, fmap => {} }, $cls;
}

sub lms_commit { delete($_[0]->{dbh})->commit }

sub lms_begin { ($_[0]->{dbh} //= dbh_new($_[0], 1))->begin_work };

sub create_tables {
	my ($dbh) = @_;

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS folders (
	fid INTEGER PRIMARY KEY,
	loc VARBINARY NOT NULL, /* URL;UIDVALIDITY=$N or $TYPE:/pathname */
	UNIQUE (loc)
)

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS blob2num (
	oidbin VARBINARY NOT NULL,
	fid INTEGER NOT NULL, /* folder ID */
	uid INTEGER NOT NULL, /* NNTP article number, IMAP UID, MH number */
	UNIQUE (oidbin, fid, uid)
)

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS blob2name (
	oidbin VARBINARY NOT NULL,
	fid INTEGER NOT NULL, /* folder ID */
	name VARBINARY NOT NULL, /* Maildir basename, JMAP blobId */
	UNIQUE (oidbin, fid, name)
)

}

sub _fid_for {
	my ($self, $folder, $rw) = @_;
	my $dbh = $self->{dbh};
	my ($row) = $dbh->selectrow_array(<<'', undef, $folder);
SELECT fid FROM folders WHERE loc = ? LIMIT 1

	return $row if defined $row;
	return unless $rw;

	($row) = $dbh->selectrow_array('SELECT MAX(fid) FROM folders');

	my $fid = ($row // 0) + 1;
	# in case we're reusing, clobber existing stale refs:
	$dbh->do('DELETE FROM blob2name WHERE fid = ?', undef, $fid);
	$dbh->do('DELETE FROM blob2num WHERE fid = ?', undef, $fid);

	my $sth = $dbh->prepare('INSERT INTO folders (fid, loc) VALUES (?, ?)');
	$sth->execute($fid, $folder);

	$fid;
}

sub set_src {
	my ($self, $oidhex, $folder, $id) = @_;
	my $fid = $self->{fmap}->{$folder} //= _fid_for($self, $folder, 1);
	my $sth;
	if (ref($id)) { # scalar name
		$id = $$id;
		$sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR IGNORE INTO blob2name (oidbin, fid, name) VALUES (?, ?, ?)

	} else { # numeric ID (IMAP UID, MH number)
		$sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR IGNORE INTO blob2num (oidbin, fid, uid) VALUES (?, ?, ?)

	}
	$sth->execute(pack('H*', $oidhex), $fid, $id);
}

sub clear_src {
	my ($self, $folder, $id) = @_;
	my $fid = $self->{fmap}->{$folder} //= _fid_for($self, $folder, 1);
	my $sth;
	if (ref($id)) { # scalar name
		$id = $$id;
		$sth = $self->{dbh}->prepare_cached(<<'');
DELETE FROM blob2name WHERE fid = ? AND name = ?

	} else {
		$sth = $self->{dbh}->prepare_cached(<<'');
DELETE FROM blob2num WHERE fid = ? AND uid = ?

	}
	$sth->execute($fid, $id);
}

# read-only, iterates every oidbin + UID or name for a given folder
sub each_src {
	my ($self, $folder, $cb, @args) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self);
	my ($fid, $sth);
	$fid = $self->{fmap}->{$folder} //= _fid_for($self, $folder) // return;
	$sth = $dbh->prepare('SELECT oidbin,uid FROM blob2num WHERE fid = ?');
	$sth->execute($fid);
	while (my ($oidbin, $id) = $sth->fetchrow_array) {
		$cb->($oidbin, $id, @args);
	}
	$sth = $dbh->prepare('SELECT oidbin,name FROM blob2name WHERE fid = ?');
	$sth->execute($fid);
	while (my ($oidbin, $id) = $sth->fetchrow_array) {
		$cb->($oidbin, \$id, @args);
	}
}

sub location_stats {
	my ($self, $folder) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self);
	my $fid;
	my $ret = {};
	$fid = $self->{fmap}->{$folder} //= _fid_for($self, $folder) // return;
	my ($row) = $dbh->selectrow_array(<<"", undef, $fid);
SELECT COUNT(name) FROM blob2name WHERE fid = ?

	$ret->{'name.count'} = $row if $row;
	for my $op (qw(count min max)) {
		($row) = $dbh->selectrow_array(<<"", undef, $fid);
SELECT $op(uid) FROM blob2num WHERE fid = ?

		$row or last;
		$ret->{"uid.$op"} = $row;
	}
	$ret;
}

# returns a { location => [ list-of-ids-or-names ] } mapping
sub locations_for {
	my ($self, $oidhex) = @_;
	my ($fid, $sth, $id, %fid2id);
	my $dbh = $self->{dbh} //= dbh_new($self);
	$sth = $dbh->prepare('SELECT fid,uid FROM blob2num WHERE oidbin = ?');
	$sth->execute(pack('H*', $oidhex));
	while (my ($fid, $uid) = $sth->fetchrow_array) {
		push @{$fid2id{$fid}}, $uid;
	}
	$sth = $dbh->prepare('SELECT fid,name FROM blob2name WHERE oidbin = ?');
	$sth->execute(pack('H*', $oidhex));
	while (my ($fid, $name) = $sth->fetchrow_array) {
		push @{$fid2id{$fid}}, $name;
	}
	$sth = $dbh->prepare('SELECT loc FROM folders WHERE fid = ? LIMIT 1');
	my $ret = {};
	while (my ($fid, $ids) = each %fid2id) {
		$sth->execute($fid);
		my ($loc) = $sth->fetchrow_array;
		unless (defined $loc) {
			warn "E: fid=$fid for $oidhex unknown:\n", map {
					'E: '.(ref() ? $$_ : "#$_")."\n";
				} @$ids;
			next;
		}
		$ret->{$loc} = $ids;
	}
	scalar(keys %$ret) ? $ret : undef;
}

# returns a list of folders used for completion
sub folders {
	my ($self, $pfx) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self);
	my $sql = 'SELECT loc FROM folders';
	my @pfx;
	if (defined $pfx) {
		$sql .= ' WHERE loc LIKE ? ESCAPE ?';
		@pfx = ($pfx, '\\');
		$pfx[0] =~ s/([%_\\])/\\$1/g; # glob chars
		$pfx[0] .= '%';
	}
	map { $_->[0] } @{$dbh->selectall_arrayref($sql, undef, @pfx)};
}

1;
