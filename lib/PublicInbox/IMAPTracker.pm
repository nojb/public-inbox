# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::IMAPTracker;
use strict;
use parent qw(PublicInbox::Lock);
use DBI;
use DBD::SQLite;
use PublicInbox::Config;

sub create_tables ($) {
	my ($dbh) = @_;

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS imap_last (
	url VARCHAR PRIMARY KEY NOT NULL,
	uid_validity INTEGER NOT NULL,
	uid INTEGER NOT NULL,
	UNIQUE (url)
)

}

sub dbh_new ($) {
	my ($dbname) = @_;
	my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname", '', '', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		sqlite_use_immediate_transaction => 1,
	});
	$dbh->{sqlite_unicode} = 1;

	# TRUNCATE reduces I/O compared to the default (DELETE).
	# Allow and preserve user-overridden WAL, but don't force it.
	my $jm = $dbh->selectrow_array('PRAGMA journal_mode');
	$dbh->do('PRAGMA journal_mode = TRUNCATE') if $jm ne 'wal';

	create_tables($dbh);
	$dbh;
}

sub get_last ($) {
	my ($self) = @_;
	my $sth = $self->{dbh}->prepare_cached(<<'', undef, 1);
SELECT uid_validity, uid FROM imap_last WHERE url = ?

	$sth->execute($self->{url});
	$sth->fetchrow_array;
}

sub update_last ($$$) {
	my ($self, $validity, $last_uid) = @_;
	return unless defined $last_uid;
	my $sth = $self->{dbh}->prepare_cached(<<'');
INSERT OR REPLACE INTO imap_last (url, uid_validity, uid)
VALUES (?, ?, ?)

	$self->lock_acquire;
	my $rv = $sth->execute($self->{url}, $validity, $last_uid);
	$self->lock_release;
	$rv;
}

sub new {
	my ($class, $url) = @_;

	# original name for compatibility with old setups:
	my $dbname = PublicInbox::Config->config_dir() . '/imap.sqlite3';

	# use the new XDG-compliant name for new setups:
	if (!-f $dbname) {
		$dbname = ($ENV{XDG_DATA_HOME} //
			(($ENV{HOME} // '/nonexistent').'/.local/share')) .
			'/public-inbox/imap.sqlite3';
	}
	if (!-f $dbname) {
		require File::Path;
		require PublicInbox::Syscall;
		my ($dir) = ($dbname =~ m!(.*?/)[^/]+\z!);
		File::Path::mkpath($dir);
		PublicInbox::Syscall::nodatacow_dir($dir);
		open my $fh, '+>>', $dbname or die "failed to open $dbname: $!";
	}
	my $self = bless { lock_path => "$dbname.lock", url => $url }, $class;
	$self->lock_acquire;
	$self->{dbh} = dbh_new($dbname);
	$self->lock_release;
	$self;
}

1;
