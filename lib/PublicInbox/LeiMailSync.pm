# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for maintaining synchronization between lei/store <=> Maildir|MH|IMAP|JMAP
package PublicInbox::LeiMailSync;
use strict;
use v5.10.1;
use DBI;
use PublicInbox::ContentHash qw(git_sha);

sub dbh_new {
	my ($self, $rw) = @_;
	my $f = $self->{filename};
	my $creat = $rw && !-s $f;
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
	my $sel = 'SELECT fid FROM folders WHERE loc = ? LIMIT 1';
	my ($fid) = $dbh->selectrow_array($sel, undef, $folder);
	return $fid if defined $fid;

	if ($folder =~ s!\A((?:maildir|mh):.*?)/+\z!$1!i) {
		warn "folder: $folder/ had trailing slash in arg\n";
		($fid) = $dbh->selectrow_array($sel, undef, $folder);
		if (defined $fid) {
			$dbh->do(<<EOM, undef, $folder, $fid) if $rw;
UPDATE folders SET loc = ? WHERE fid = ?
EOM
			return $fid;
		}
	# sometimes we stored trailing slash..
	} elsif ($folder =~ m!\A(?:maildir|mh):!i) {
		($fid) = $dbh->selectrow_array($sel, undef, "$folder/");
		if (defined $fid) {
			$dbh->do(<<EOM, undef, $folder, $fid) if $rw;
UPDATE folders SET loc = ? WHERE fid = ?
EOM
			return $fid;
		}
	}
	return unless $rw;

	($fid) = $dbh->selectrow_array('SELECT MAX(fid) FROM folders');

	$fid += 1;
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

# Maildir-only
sub mv_src {
	my ($self, $folder, $oidbin, $id, $newbn) = @_;
	my $fid = $self->{fmap}->{$folder} //= _fid_for($self, $folder, 1);
	my $sth = $self->{dbh}->prepare_cached(<<'');
UPDATE blob2name SET name = ? WHERE fid = ? AND oidbin = ? AND name = ?

	$sth->execute($newbn, $fid, $oidbin, $$id);
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

sub local_blob {
	my ($self, $oidhex, $vrfy) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self);
	my $b2n = $dbh->prepare(<<'');
SELECT f.loc,b.name FROM blob2name b
LEFT JOIN folders f ON b.fid = f.fid
WHERE b.oidbin = ?

	$b2n->execute(pack('H*', $oidhex));
	while (my ($d, $n) = $b2n->fetchrow_array) {
		substr($d, 0, length('maildir:')) = '';
		# n.b. both mbsync and offlineimap use ":2," as a suffix
		# in "new/", despite (from what I understand of reading
		# <https://cr.yp.to/proto/maildir.html>), the ":2," only
		# applies to files in "cur/".
		my @try = $n =~ /:2,[a-zA-Z]+\z/ ? qw(cur new) : qw(new cur);
		for my $x (@try) {
			my $f = "$d/$x/$n";
			open my $fh, '<', $f or next;
			# some (buggy) Maildir writers are non-atomic:
			next unless -s $fh;
			local $/;
			my $raw = <$fh>;
			if ($vrfy && git_sha(1, \$raw)->hexdigest ne $oidhex) {
				warn "$f changed $oidhex\n";
				next;
			}
			return \$raw;
		}
	}
	undef;
}

sub match_imap_url {
	my ($self, $url, $all) = @_; # $all = [ $lms->folders ];
	$all //= [ $self->folders ];
	require PublicInbox::URIimap;
	my $want = PublicInbox::URIimap->new($url)->canonical;
	my ($s, $h, $mb) = ($want->scheme, $want->host, $want->mailbox);
	my @uri = map { PublicInbox::URIimap->new($_)->canonical }
		grep(m!\A\Q$s\E://.*?\Q$h\E\b.*?/\Q$mb\E\b!, @$all);
	my @match;
	for my $x (@uri) {
		next if $x->mailbox ne $want->mailbox;
		next if $x->host ne $want->host;
		next if $x->port != $want->port;
		my $x_uidval = $x->uidvalidity;
		next if ($want->uidvalidity // $x_uidval) != $x_uidval;

		# allow nothing in want to possibly match ";AUTH=ANONYMOUS"
		if (defined($x->auth) && !defined($want->auth) &&
				!defined($want->user)) {
			push @match, $x;
		# or maybe user was forgotten on CLI:
		} elsif (defined($x->user) && !defined($want->user)) {
			push @match, $x;
		} elsif (($x->user//"\0") eq ($want->user//"\0")) {
			push @match, $x;
		}
	}
	return @match if wantarray;
	scalar(@match) <= 1 ? $match[0] :
			"E: `$url' is ambiguous:\n\t".join("\n\t", @match)."\n";
}

1;
