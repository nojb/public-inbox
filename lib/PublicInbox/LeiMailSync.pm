# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for maintaining synchronization between lei/store <=> Maildir|MH|IMAP|JMAP
package PublicInbox::LeiMailSync;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock);
use DBI;
use PublicInbox::ContentHash qw(git_sha);
use Carp ();

sub dbh_new {
	my ($self, $rw) = @_;
	my $f = $self->{filename};
	my $creat = $rw && !-s $f;
	if ($creat) {
		require PublicInbox::Spawn;
		open my $fh, '+>>', $f or Carp::croak "open($f): $!";
		PublicInbox::Spawn::nodatacow_fd(fileno($fh));
	}
	my $dbh = DBI->connect("dbi:SQLite:dbname=$f",'','', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		ReadOnly => !$rw,
		sqlite_use_immediate_transaction => 1,
	});
	# no sqlite_unicode, here, all strings are binary
	create_tables($self, $dbh) if $rw;
	$dbh->do('PRAGMA journal_mode = WAL') if $creat;
	$dbh->do('PRAGMA case_sensitive_like = ON');
	$dbh;
}

sub new {
	my ($cls, $f) = @_;
	bless {
		filename => $f,
		fmap => {},
		lock_path => "$f.flock",
	}, $cls;
}

sub lms_write_prepare { ($_[0]->{dbh} //= dbh_new($_[0], 1)); $_[0] }

sub lms_pause {
	my ($self) = @_;
	$self->{fmap} = {};
	my $dbh = delete $self->{dbh};
	$dbh->do('PRAGMA optimize') if $dbh;
}

sub create_tables {
	my ($self, $dbh) = @_;
	my $lk = $self->lock_for_scope;

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
	/* not UNIQUE(fid, uid), since we may have broken servers */
	UNIQUE (oidbin, fid, uid)
)

	# speeds up LeiImport->ck_update_kw (for "lei import") by 5-6x:
	$dbh->do(<<'');
CREATE INDEX IF NOT EXISTS idx_fid_uid ON blob2num(fid,uid)

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS blob2name (
	oidbin VARBINARY NOT NULL,
	fid INTEGER NOT NULL, /* folder ID */
	name VARBINARY NOT NULL, /* Maildir basename, JMAP blobId */
	/* not UNIQUE(fid, name), since we may have broken software */
	UNIQUE (oidbin, fid, name)
)

	# speeds up LeiImport->pmdir_cb (for "lei import") by ~6x:
	$dbh->do(<<'');
CREATE INDEX IF NOT EXISTS idx_fid_name ON blob2name(fid,name)

}

sub fid_for {
	my ($self, $folder, $rw) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self, $rw);
	my $sel = 'SELECT fid FROM folders WHERE loc = ? LIMIT 1';
	my ($fid) = $dbh->selectrow_array($sel, undef, $folder);
	return $fid if defined $fid;

	# caller had trailing slash (LeiToMail)
	if ($folder =~ s!\A((?:maildir|mh):.*?)/+\z!$1!i) {
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
	} elsif ($rw && $folder =~ m!\Aimaps?://!i) {
		require PublicInbox::URIimap;
		PublicInbox::URIimap->new($folder)->uidvalidity //
			Carp::croak("BUG: $folder has no UIDVALIDITY");
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

sub add_folders {
	my ($self, @folders) = @_;
	my $lk = $self->lock_for_scope;
	for my $f (@folders) { $self->{fmap}->{$f} //= fid_for($self, $f, 1) }
}

sub set_src {
	my ($self, $oidbin, $folder, $id) = @_;
	my $lk = $self->lock_for_scope;
	my $fid = $self->{fmap}->{$folder} //= fid_for($self, $folder, 1);
	my $sth;
	if (ref($id)) { # scalar name
		$id = $$id;
		$sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR IGNORE INTO blob2name (oidbin, fid, name) VALUES (?, ?, ?)

	} else { # numeric ID (IMAP UID, MH number)
		$sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR IGNORE INTO blob2num (oidbin, fid, uid) VALUES (?, ?, ?)

	}
	$sth->execute($oidbin, $fid, $id);
}

sub clear_src {
	my ($self, $folder, $id) = @_;
	my $lk = $self->lock_for_scope;
	my $fid = $self->{fmap}->{$folder} //= fid_for($self, $folder, 1);
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
	my $lk = $self->lock_for_scope;
	my $fid = $self->{fmap}->{$folder} //= fid_for($self, $folder, 1);
	my $sth = $self->{dbh}->prepare_cached(<<'');
UPDATE blob2name SET name = ? WHERE fid = ? AND oidbin = ? AND name = ?

	my $nr = $sth->execute($newbn, $fid, $oidbin, $$id);
	if ($nr == 0) { # may race with a clear_src, ensure new value exists
		$sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR IGNORE INTO blob2name (oidbin, fid, name) VALUES (?, ?, ?)

		$sth->execute($oidbin, $fid, $newbn);
	}
}

# read-only, iterates every oidbin + UID or name for a given folder
sub each_src {
	my ($self, $folder, $cb, @args) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self);
	my ($fid, @rng);
	my $and_ge_le = '';
	if (ref($folder) eq 'HASH') {
		$fid = $folder->{fid} // die "BUG: no `fid'";
		@rng = grep(defined, @$folder{qw(min max)});
		$and_ge_le = 'AND uid >= ? AND uid <= ?' if @rng;
	} else {
		$fid = $self->{fmap}->{$folder} //=
			fid_for($self, $folder) // return;
	}

	# minimize implicit txn time to avoid blocking writers by
	# batching SELECTs.  This looks wonky but is necessary since
	# $cb-> may access the DB on its own.
	my $ary = $dbh->selectall_arrayref(<<"", undef, $fid, @rng);
SELECT _rowid_,oidbin,uid FROM blob2num WHERE fid = ? $and_ge_le
ORDER BY _rowid_ ASC LIMIT 1000

	my $min = @$ary ? $ary->[-1]->[0] : undef;
	while (defined $min) {
		for my $row (@$ary) { $cb->($row->[1], $row->[2], @args) }

		$ary = $dbh->selectall_arrayref(<<"", undef, $fid, @rng, $min);
SELECT _rowid_,oidbin,uid FROM blob2num
WHERE fid = ? $and_ge_le AND _rowid_ > ?
ORDER BY _rowid_ ASC LIMIT 1000

		$min = @$ary ? $ary->[-1]->[0] : undef;
	}

	$ary = $dbh->selectall_arrayref(<<'', undef, $fid);
SELECT _rowid_,oidbin,name FROM blob2name WHERE fid = ?
ORDER BY _rowid_ ASC LIMIT 1000

	$min = @$ary ? $ary->[-1]->[0] : undef;
	while (defined $min) {
		for my $row (@$ary) { $cb->($row->[1], \($row->[2]), @args) }

		$ary = $dbh->selectall_arrayref(<<'', undef, $fid, $min);
SELECT _rowid_,oidbin,name FROM blob2name WHERE fid = ? AND _rowid_ > ?
ORDER BY _rowid_ ASC LIMIT 1000

		$min = @$ary ? $ary->[-1]->[0] : undef;
	}
}

sub location_stats {
	my ($self, $folder) = @_;
	my $dbh = $self->{dbh} //= dbh_new($self);
	my $fid;
	my $ret = {};
	$fid = $self->{fmap}->{$folder} //= fid_for($self, $folder) // return;
	my ($row) = $dbh->selectrow_array(<<"", undef, $fid);
SELECT COUNT(name) FROM blob2name WHERE fid = ?

	$ret->{'name.count'} = $row if $row;
	my $ntype = ($folder =~ m!\A(?:nntps?|s?news)://!i) ? 'article' :
		(($folder =~ m!\Aimaps?://!i) ? 'uid' : "TODO<$folder>");
	for my $op (qw(count min max)) {
		($row) = $dbh->selectrow_array(<<"", undef, $fid);
SELECT $op(uid) FROM blob2num WHERE fid = ?

		$row or last;
		$ret->{"$ntype.$op"} = $row;
	}
	$ret;
}

# returns a { location => [ list-of-ids-or-names ] } mapping
sub locations_for {
	my ($self, $oidbin) = @_;
	my ($fid, $sth, $id, %fid2id);
	my $dbh = $self->{dbh} //= dbh_new($self);
	$sth = $dbh->prepare('SELECT fid,uid FROM blob2num WHERE oidbin = ?');
	$sth->execute($oidbin);
	while (my ($fid, $uid) = $sth->fetchrow_array) {
		push @{$fid2id{$fid}}, $uid;
	}
	$sth = $dbh->prepare('SELECT fid,name FROM blob2name WHERE oidbin = ?');
	$sth->execute($oidbin);
	while (my ($fid, $name) = $sth->fetchrow_array) {
		push @{$fid2id{$fid}}, $name;
	}
	$sth = $dbh->prepare('SELECT loc FROM folders WHERE fid = ? LIMIT 1');
	my $ret = {};
	while (my ($fid, $ids) = each %fid2id) {
		$sth->execute($fid);
		my ($loc) = $sth->fetchrow_array;
		unless (defined $loc) {
			my $oidhex = unpack('H*', $oidbin);
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
	my ($self, @pfx) = @_;
	my $sql = 'SELECT loc FROM folders';
	if (defined($pfx[0])) {
		$sql .= ' WHERE loc LIKE ? ESCAPE ?';
		my $anywhere = !!$pfx[1];
		$pfx[1] = '\\';
		$pfx[0] =~ s/([%_\\])/\\$1/g; # glob chars
		$pfx[0] .= '%';
		substr($pfx[0], 0, 0, '%') if $anywhere;
	} else {
		@pfx = (); # [0] may've been undef
	}
	my $dbh = $self->{dbh} //= dbh_new($self);
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

sub match_nntp_url ($$$) {
	my ($self, $url, $all) = @_; # $all = [ $lms->folders ];
	$all //= [ $self->folders ];
	require PublicInbox::URInntps;
	my $want = PublicInbox::URInntps->new($url)->canonical;
	my ($s, $h, $p) = ($want->scheme, $want->host, $want->port);
	my $ng = $want->group; # force scalar (no article ranges)
	my @uri = map { PublicInbox::URInntps->new($_)->canonical }
		grep(m!\A\Q$s\E://.*?\Q$h\E\b.*?/\Q$ng\E\b!, @$all);
	my @match;
	for my $x (@uri) {
		next if $x->group ne $ng || $x->host ne $h || $x->port != $p;
		# maybe user was forgotten on CLI:
		if (defined($x->userinfo) && !defined($want->userinfo)) {
			push @match, $x;
		} elsif (($x->userinfo//"\0") eq ($want->userinfo//"\0")) {
			push @match, $x;
		}
	}
	return @match if wantarray;
	scalar(@match) <= 1 ? $match[0] :
			"E: `$url' is ambiguous:\n\t".join("\n\t", @match)."\n";
}

# returns undef on failure, number on success
sub group2folders {
	my ($self, $lei, $all, $folders) = @_;
	return $lei->fail(<<EOM) if @$folders;
--all= not compatible with @$folders on command-line
EOM
	my %x = map { $_ => $_ } split(/,/, $all);
	my @ok = grep(defined, delete(@x{qw(local remote), ''}));
	push(@ok, '') if $all eq '';
	my @no = keys %x;
	if (@no) {
		@no = (join(',', @no));
		return $lei->fail(<<EOM);
--all=@no not accepted (must be `local' and/or `remote')
EOM
	}
	my (%seen, @inc);
	my @all = $self->folders;
	for my $ok (@ok) {
		if ($ok eq 'local') {
			@inc = grep(!m!\A[a-z0-9\+]+://!i, @all);
		} elsif ($ok eq 'remote') {
			@inc = grep(m!\A[a-z0-9\+]+://!i, @all);
		} elsif ($ok ne '') {
			return $lei->fail("--all=$all not understood");
		} else {
			@inc = @all;
		}
		push(@$folders, (grep { !$seen{$_}++ } @inc));
	}
	scalar(@$folders) || $lei->fail(<<EOM);
no --mail-sync folders known to lei
EOM
}

# map CLI args to folder table entries, returns undef on failure
sub arg2folder {
	my ($self, $lei, $folders) = @_;
	my @all = $self->folders;
	my %all = map { $_ => 1 } @all;
	my @no;
	for (@$folders) {
		next if $all{$_}; # ok
		if (m!\A(maildir|mh):(.+)!i) {
			my $type = lc $1;
			my $d = "$type:".$lei->abs_path($2);
			push(@no, $_) unless $all{$d};
			$_ = $d;
		} elsif (-d "$_/new" && -d "$_/cur") {
			my $d = 'maildir:'.$lei->abs_path($_);
			push(@no, $_) unless $all{$d};
			$_ = $d;
		} elsif (m!\Aimaps?://!i) {
			my $orig = $_;
			my $res = match_imap_url($self, $orig, \@all);
			if (ref $res) {
				$_ = $$res;
				$lei->qerr(<<EOM);
# using `$res' instead of `$orig'
EOM
			} else {
				$lei->err($res) if defined $res;
				push @no, $orig;
			}
		} elsif (m!\A(?:nntps?|s?news)://!i) {
			my $orig = $_;
			my $res = match_nntp_url($self, $orig, \@all);
			if (ref $res) {
				$_ = $$res;
				$lei->qerr(<<EOM);
# using `$res' instead of `$orig'
EOM
			} else {
				$lei->err($res) if defined $res;
				push @no, $orig;
			}
		} else {
			push @no, $_;
		}
	}
	if (@no) {
		my $no = join("\n\t", @no);
		die <<EOF;
No sync information for: $no
Run `lei ls-mail-sync' to display valid choices
EOF
	}
}

sub forget_folders {
	my ($self, @folders) = @_;
	my $lk = $self->lock_for_scope;
	for my $folder (@folders) {
		my $fid = delete($self->{fmap}->{$folder}) //
			fid_for($self, $folder) // next;
		for my $t (qw(blob2name blob2num folders)) {
			$self->{dbh}->do("DELETE FROM $t WHERE fid = ?",
					undef, $fid);
		}
	}
}

# only used for changing canonicalization errors
sub rename_folder {
	my ($self, $old, $new) = @_;
	my $lk = $self->lock_for_scope;
	my $ofid = delete($self->{fmap}->{$old}) //
		fid_for($self, $old) // return;
	eval {
		$self->{dbh}->do(<<EOM, undef, $new, $ofid);
UPDATE folders SET loc = ? WHERE fid = ?
EOM
	};
	if ($@ =~ /\bunique\b/i) {
		my $nfid = $self->{fmap}->{$new} // fid_for($self, $new);
		for my $t (qw(blob2name blob2num)) {
			$self->{dbh}->do(<<EOM, undef, $nfid, $ofid);
UPDATE OR REPLACE $t SET fid = ? WHERE fid = ?
EOM
		}
		$self->{dbh}->do(<<EOM, undef, $ofid);
DELETE FROM folders WHERE fid = ?
EOM
	}
}

sub num_oidbin ($$$) {
	my ($self, $url, $uid) = @_; # $url MUST have UIDVALIDITY if IMAP
	my $fid = $self->{fmap}->{$url} //= fid_for($self, $url) // return ();
	my $sth = $self->{dbh}->prepare_cached(<<EOM, undef, 1);
SELECT oidbin FROM blob2num WHERE fid = ? AND uid = ? ORDER BY _rowid_
EOM
	$sth->execute($fid, $uid);
	map { $_->[0] } @{$sth->fetchall_arrayref};
}

sub name_oidbin ($$$) {
	my ($self, $mdir, $nm) = @_;
	my $fid = $self->{fmap}->{$mdir} //= fid_for($self, $mdir) // return;
	my $sth = $self->{dbh}->prepare_cached(<<EOM, undef, 1);
SELECT oidbin FROM blob2name WHERE fid = ? AND name = ?
EOM
	$sth->execute($fid, $nm);
	map { $_->[0] } @{$sth->fetchall_arrayref};
}

sub imap_oidhex {
	my ($self, $lei, $uid_uri) = @_;
	my $mailbox_uri = $uid_uri->clone;
	$mailbox_uri->uid(undef);
	my $folders = [ $$mailbox_uri ];
	eval { $self->arg2folder($lei, $folders) };
	$lei->qerr("# no sync information for $mailbox_uri") if $@;
	map { unpack('H*',$_) } num_oidbin($self, $folders->[0], $uid_uri->uid)
}

1;
