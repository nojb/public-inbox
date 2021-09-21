# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# fork()-friendly key-value store.  Will be used for making
# augmenting Maildirs and mboxes less expensive, maybe.
# We use flock(2) to avoid SQLite lock problems (busy timeouts, backoff)
package PublicInbox::SharedKV;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock);
use File::Temp qw(tempdir);
use DBI ();
use PublicInbox::Spawn;
use File::Path qw(rmtree make_path);

sub dbh {
	my ($self, $lock) = @_;
	$self->{dbh} //= do {
		my $f = $self->{filename};
		$lock //= $self->lock_for_scope_fast;
		my $dbh = DBI->connect("dbi:SQLite:dbname=$f", '', '', {
			AutoCommit => 1,
			RaiseError => 1,
			PrintError => 0,
			sqlite_use_immediate_transaction => 1,
			# no sqlite_unicode here, this is for binary data
		});
		my $opt = $self->{opt} // {};
		$dbh->do('PRAGMA synchronous = OFF') if !$opt->{fsync};
		if (my $s = $opt->{cache_size}) {
			$dbh->do("PRAGMA cache_size = $s");
		}
		$dbh->do('PRAGMA journal_mode = '.
				($opt->{journal_mode} // 'WAL'));
		$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS kv (
	k VARBINARY PRIMARY KEY NOT NULL,
	v VARBINARY NOT NULL,
	UNIQUE (k)
)

		$dbh;
	}
}

sub new {
	my ($cls, $dir, $base, $opt) = @_;
	my $self = bless { opt => $opt }, $cls;
	make_path($dir) if defined($dir) && !-d $dir;
	$dir //= $self->{"tmp$$.$self"} = tempdir("skv.$$-XXXX", TMPDIR => 1);
	$base //= '';
	my $f = $self->{filename} = "$dir/$base.sqlite3";
	$self->{lock_path} = $opt->{lock_path} // "$dir/$base.flock";
	unless (-f $f) {
		open my $fh, '+>>', $f or die "failed to open $f: $!";
		PublicInbox::Spawn::nodatacow_fd(fileno($fh));
	}
	$self;
}

sub index_values {
	my ($self) = @_;
	my $lock = $self->lock_for_scope_fast;
	$self->dbh($lock)->do('CREATE INDEX IF NOT EXISTS idx_v ON kv (v)');
}

sub set_maybe {
	my ($self, $key, $val, $lock) = @_;
	$lock //= $self->lock_for_scope_fast;
	my $e = $self->{dbh}->prepare_cached(<<'')->execute($key, $val);
INSERT OR IGNORE INTO kv (k,v) VALUES (?, ?)

	$e == 0 ? undef : $e;
}

# caller calls sth->fetchrow_array
sub each_kv_iter {
	my ($self) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<'', undef, 1);
SELECT k,v FROM kv

	$sth->execute;
	$sth
}

sub keys {
	my ($self, @pfx) = @_;
	my $sql = 'SELECT k FROM kv';
	if (defined $pfx[0]) {
		$sql .= ' WHERE k LIKE ? ESCAPE ?';
		my $anywhere = !!$pfx[1];
		$pfx[1] = '\\';
		$pfx[0] =~ s/([%_\\])/\\$1/g; # glob chars
		$pfx[0] .= '%';
		substr($pfx[0], 0, 0, '%') if $anywhere;
	} else {
		@pfx = (); # [0] may've been undef
	}
	map { $_->[0] } @{$self->dbh->selectall_arrayref($sql, undef, @pfx)};
}

sub delete_by_val {
	my ($self, $val, $lock) = @_;
	$lock //= $self->lock_for_scope_fast;
	$self->{dbh}->prepare_cached(<<'')->execute($val) + 0;
DELETE FROM kv WHERE v = ?

}

sub replace_values {
	my ($self, $oldval, $newval, $lock) = @_;
	$lock //= $self->lock_for_scope_fast;
	$self->{dbh}->prepare_cached(<<'')->execute($newval, $oldval) + 0;
UPDATE kv SET v = ? WHERE v = ?

}

sub set {
	my ($self, $key, $val) = @_;
	if (defined $val) {
		my $e = $self->{dbh}->prepare_cached(<<'')->execute($key, $val);
INSERT OR REPLACE INTO kv (k,v) VALUES (?,?)

		$e == 0 ? undef : $e;
	} else {
		$self->{dbh}->prepare_cached(<<'')->execute($key);
DELETE FROM kv WHERE k = ?

	}
}

sub get {
	my ($self, $key) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<'', undef, 1);
SELECT v FROM kv WHERE k = ?

	$sth->execute($key);
	$sth->fetchrow_array;
}

sub xchg {
	my ($self, $key, $newval, $lock) = @_;
	$lock //= $self->lock_for_scope_fast;
	my $oldval = get($self, $key);
	if (defined $newval) {
		set($self, $key, $newval);
	} else {
		$self->{dbh}->prepare_cached(<<'')->execute($key);
DELETE FROM kv WHERE k = ?

	}
	$oldval;
}

sub count {
	my ($self) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<'');
SELECT COUNT(k) FROM kv

	$sth->execute;
	$sth->fetchrow_array;
}

# faster than ->count due to how SQLite works
sub has_entries {
	my ($self) = @_;
	my @n = $self->{dbh}->selectrow_array('SELECT k FROM kv LIMIT 1');
	scalar(@n) ? 1 : undef;
}

sub dbh_release {
	my ($self, $lock) = @_;
	my $dbh = delete $self->{dbh} or return;
	$lock //= $self->lock_for_scope_fast; # may be needed for WAL
	%{$dbh->{CachedKids}} = (); # cleanup prepare_cached
	$dbh->disconnect;
}

sub DESTROY {
	my ($self) = @_;
	dbh_release($self);
	my $dir = delete $self->{"tmp$$.$self"} or return;
	my $tries = 0;
	do {
		$! = 0;
		eval { rmtree($dir) };
	} while ($@ && $!{ENOENT} && $tries++ < 5);
	warn "error removing $dir: $@" if $@;
	warn "Took $tries tries to remove $dir\n" if $tries;
}

1;
