# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an POP3D
package PublicInbox::POP3D;
use v5.12;
use parent qw(PublicInbox::Lock);
use DBI qw(:sql_types); # SQL_BLOB
use Carp ();
use File::Temp 0.19 (); # 0.19 for ->newdir
use PublicInbox::Config;
use PublicInbox::POP3;
use PublicInbox::Syscall;
use File::Temp 0.19 (); # 0.19 for ->newdir
use Fcntl qw(F_SETLK F_UNLCK F_WRLCK SEEK_SET);
my @FLOCK;
if ($^O eq 'linux' || $^O =~ /bsd/) {
	require Config;
	my $off_t;
	my $sz = $Config::Config{lseeksize};

	if ($sz == 8 && eval('length(pack("q", 1)) == 8')) { $off_t = 'q' }
	elsif ($sz == 4) { $off_t = 'l' }
	else { warn "sizeof(off_t)=$sz requires File::FcntlLock\n" }

	if (defined($off_t)) {
		if ($^O eq 'linux') {
			@FLOCK = ("ss\@8$off_t$off_t\@32",
				qw(l_type l_whence l_start l_len));
		} elsif ($^O =~ /bsd/) {
			@FLOCK = ("${off_t}${off_t}lss\@256",
				qw(l_start l_len l_pid l_type l_whence));
		}
	}
}
@FLOCK or eval { require File::FcntlLock } or
	die "File::FcntlLock required for POP3 on $^O: $@\n";

sub new {
	my ($cls) = @_;
	bless {
		err => \*STDERR,
		out => \*STDOUT,
		# pi_cfg => PublicInbox::Config
		# lock_path => ...
		# interprocess lock is the $pop3state/txn.locks file
		# txn_locks => {}, # intraworker locks
		# ssl_ctx_opt => { SSL_cert_file => ..., SSL_key_file => ... }
	}, $cls;
}

sub refresh_groups { # PublicInbox::Daemon callback
	my ($self, $sig) = @_;
	# TODO share pi_cfg with nntpd/imapd inside -netd
	my $new = PublicInbox::Config->new;
	my $d = $new->{'publicinbox.pop3state'} //
		die "publicinbox.pop3state undefined ($new->{-f})\n";
	-d $d or do {
		require File::Path;
		File::Path::make_path($d, { mode => 0700 });
		PublicInbox::Syscall::nodatacow_dir($d);
	};
	$self->{lock_path} //= "$d/db.lock";
	if (my $old = $self->{pi_cfg}) {
		my $s = 'publicinbox.pop3state';
		$new->{$s} //= $old->{$s};
		return warn <<EOM if $new->{$s} ne $old->{$s};
$s changed: `$old->{$s}' => `$new->{$s}', config reload ignored
EOM
	}
	$self->{pi_cfg} = $new;
}

# persistent tables
sub create_state_tables ($$) {
	my ($self, $dbh) = @_;

	$dbh->do(<<''); # map publicinbox.<name>.newsgroup to integers
CREATE TABLE IF NOT EXISTS newsgroups (
	newsgroup_id INTEGER PRIMARY KEY NOT NULL,
	newsgroup VARBINARY NOT NULL,
	UNIQUE (newsgroup) )

	# the $NEWSGROUP_NAME.$SLICE_INDEX is part of the POP3 username;
	# POP3 has no concept of folders/mailboxes like IMAP/JMAP
	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS mailboxes (
	mailbox_id INTEGER PRIMARY KEY NOT NULL,
	newsgroup_id INTEGER NOT NULL REFERENCES newsgroups,
	slice INTEGER NOT NULL, /* -1 for most recent slice */
	UNIQUE (newsgroup_id, slice) )

	$dbh->do(<<''); # actual users are differentiated by their UUID
CREATE TABLE IF NOT EXISTS users (
	user_id INTEGER PRIMARY KEY NOT NULL,
	uuid VARBINARY NOT NULL,
	last_seen INTEGER NOT NULL, /* to expire idle accounts */
	UNIQUE (uuid) )

	# we only track the highest-numbered deleted message per-UUID@mailbox
	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS deletes (
	txn_id INTEGER PRIMARY KEY NOT NULL, /* -1 == txn lock offset */
	user_id INTEGER NOT NULL REFERENCES users,
	mailbox_id INTEGER NOT NULL REFERENCES mailboxes,
	uid_dele INTEGER NOT NULL DEFAULT -1, /* IMAP UID, NNTP article */
	UNIQUE(user_id, mailbox_id) )

}

sub state_dbh_new {
	my ($self) = @_;
	my $f = "$self->{pi_cfg}->{'publicinbox.pop3state'}/db.sqlite3";
	my $creat = !-s $f;
	if ($creat) {
		open my $fh, '+>>', $f or Carp::croak "open($f): $!";
		PublicInbox::Syscall::nodatacow_fh($fh);
	}

	my $dbh = DBI->connect("dbi:SQLite:dbname=$f",'','', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		sqlite_use_immediate_transaction => 1,
		sqlite_see_if_its_a_number => 1,
	});
	$dbh->do('PRAGMA journal_mode = WAL') if $creat;
	$dbh->do('PRAGMA foreign_keys = ON'); # don't forget this

	# ensure the interprocess fcntl lock file exists
	$f = "$self->{pi_cfg}->{'publicinbox.pop3state'}/txn.locks";
	open my $fh, '+>>', $f or Carp::croak("open($f): $!");
	$self->{txn_fh} = $fh;

	create_state_tables($self, $dbh);
	$dbh;
}

sub _setlk ($%) {
	my ($self, %lk) = @_;
	$lk{l_pid} = 0; # needed for *BSD
	$lk{l_whence} = SEEK_SET;
	if (@FLOCK) {
		fcntl($self->{txn_fh}, F_SETLK,
			pack($FLOCK[0], @lk{@FLOCK[1..$#FLOCK]}));
	} else {
		my $fs = File::FcntlLock->new(%lk);
		$fs->lock($self->{txn_fh}, F_SETLK);
	}
}

sub lock_mailbox {
	my ($self, $pop3) = @_; # pop3 - PublicInbox::POP3 client object
	my $lk = $self->lock_for_scope; # lock the SQLite DB, only
	my $dbh = $self->{-state_dbh} //= state_dbh_new($self);
	my ($user_id, $ngid, $mbid, $txn_id);
	my $uuid = delete $pop3->{uuid};
	$dbh->begin_work;

	# 1. make sure the user exists, update `last_seen'
	my $sth = $dbh->prepare_cached(<<'');
INSERT OR IGNORE INTO users (uuid, last_seen) VALUES (?,?)

	$sth->bind_param(1, $uuid, SQL_BLOB);
	$sth->bind_param(2, time);
	if ($sth->execute == 0) { # existing user
		$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT user_id FROM users WHERE uuid = ?

		$sth->bind_param(1, $uuid, SQL_BLOB);
		$sth->execute;
		$user_id = $sth->fetchrow_array //
			die 'BUG: user '.unpack('H*', $uuid).' not found';
		$sth = $dbh->prepare_cached(<<'');
UPDATE users SET last_seen = ? WHERE user_id = ?

		$sth->execute(time, $user_id);
	} else { # new user
		$user_id = $dbh->last_insert_id(undef, undef,
						'users', 'user_id')
	}

	# 2. make sure the newsgroup has an integer ID
	$sth = $dbh->prepare_cached(<<'');
INSERT OR IGNORE INTO newsgroups (newsgroup) VALUES (?)

	my $ng = $pop3->{ibx}->{newsgroup};
	$sth->bind_param(1, $ng, SQL_BLOB);
	if ($sth->execute == 0) {
		$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT newsgroup_id FROM newsgroups WHERE newsgroup = ?

		$sth->bind_param(1, $ng, SQL_BLOB);
		$sth->execute;
		$ngid = $sth->fetchrow_array // die "BUG: `$ng' not found";
	} else {
		$ngid = $dbh->last_insert_id(undef, undef,
						'newsgroups', 'newsgroup_id');
	}

	# 3. ensure the mailbox exists
	$sth = $dbh->prepare_cached(<<'');
INSERT OR IGNORE INTO mailboxes (newsgroup_id, slice) VALUES (?,?)

	if ($sth->execute($ngid, $pop3->{slice}) == 0) {
		$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT mailbox_id FROM mailboxes WHERE newsgroup_id = ? AND slice = ?

		$sth->execute($ngid, $pop3->{slice});
		$mbid = $sth->fetchrow_array //
			die "BUG: mailbox_id for $ng.$pop3->{slice} not found";
	} else {
		$mbid = $dbh->last_insert_id(undef, undef,
						'mailboxes', 'mailbox_id');
	}

	# 4. ensure the (max) deletes row exists for locking
	$sth = $dbh->prepare_cached(<<'');
INSERT OR IGNORE INTO deletes (user_id,mailbox_id) VALUES (?,?)

	if ($sth->execute($user_id, $mbid) == 0) {
		$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT txn_id,uid_dele FROM deletes WHERE user_id = ? AND mailbox_id = ?

		$sth->execute($user_id, $mbid);
		($txn_id, $pop3->{uid_dele}) = $sth->fetchrow_array;
	} else {
		$txn_id = $dbh->last_insert_id(undef, undef,
						'deletes', 'txn_id');
	}
	$dbh->commit;

	# see if it's locked by the same worker:
	return if $self->{txn_locks}->{$txn_id};

	# see if it's locked by another worker:
	_setlk($self, l_type => F_WRLCK, l_start => $txn_id - 1, l_len => 1)
		or return;

	$pop3->{user_id} = $user_id;
	$pop3->{txn_id} = $txn_id;
	$self->{txn_locks}->{$txn_id} = 1;
}

sub unlock_mailbox {
	my ($self, $pop3) = @_;
	my $txn_id = delete($pop3->{txn_id}) // return;
	if (!$pop3->{did_quit}) { # deal with QUIT-less disconnects
		my $lk = $self->lock_for_scope;
		$self->{-state_dbh}->begin_work;
		$pop3->__cleanup_state($txn_id);
		$self->{-state_dbh}->commit;
	}
	delete $self->{txn_locks}->{$txn_id}; # same worker

	# other workers
	_setlk($self, l_type => F_UNLCK, l_start => $txn_id - 1, l_len => 1)
		or die "F_UNLCK: $!";
}

1;
