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
use File::Path qw(rmtree);

sub dbh {
	my ($self, $lock) = @_;
	$self->{dbh} //= do {
		my $f = $self->{filename};
		$lock //= $self->lock_for_scope;
		my $dbh = DBI->connect("dbi:SQLite:dbname=$f", '', '', {
			AutoCommit => 1,
			RaiseError => 1,
			PrintError => 0,
			sqlite_use_immediate_transaction => 1,
			# no sqlite_unicode here, this is for binary data
		});
		my $opt = $self->{opt} // {};
		$dbh->do('PRAGMA synchronous = OFF') if !$opt->{fsync};
		$dbh->do('PRAGMA cache_size = '.($opt->{cache_size} || 80000));
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
	unless (defined $dir) {
		$self->{tmpdir} = $dir = tempdir('skv-XXXXXX', TMPDIR => 1);
		$self->{tmpid} = "$$.$self";
	}
	-d $dir or mkdir($dir) or die "mkdir($dir): $!";
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
	my $lock = $self->lock_for_scope;
	$self->dbh($lock)->do('CREATE INDEX IF NOT EXISTS idx_v ON kv (v)');
}

sub set_maybe {
	my ($self, $key, $val, $lock) = @_;
	$lock //= $self->lock_for_scope;
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

sub delete_by_val {
	my ($self, $val, $lock) = @_;
	$lock //= $self->lock_for_scope;
	$self->{dbh}->prepare_cached(<<'')->execute($val) + 0;
DELETE FROM kv WHERE v = ?

}

sub replace_values {
	my ($self, $oldval, $newval, $lock) = @_;
	$lock //= $self->lock_for_scope;
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
	$lock //= $self->lock_for_scope;
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

sub DESTROY {
	my ($self) = @_;
	rmtree($self->{tmpdir}) if ($self->{tmpid} // '') eq "$$.$self";
}

1;
