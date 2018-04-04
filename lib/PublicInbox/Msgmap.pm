# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# bidirectional Message-ID <-> Article Number mapping for the NNTP
# and web interfaces.  This is required for implementing stable article
# numbers for NNTP and allows prefix lookups for partial Message-IDs
# in case URLs get truncated from copy-n-paste errors by users.
#
# This is maintained by ::SearchIdx
package PublicInbox::Msgmap;
use strict;
use warnings;
use DBI;
use DBD::SQLite;
use File::Temp qw(tempfile);

sub new {
	my ($class, $git_dir, $writable) = @_;
	my $d = "$git_dir/public-inbox";
	if ($writable && !-d $d && !mkdir $d) {
		my $err = $!;
		-d $d or die "$d not created: $err";
	}
	new_file($class, "$d/msgmap.sqlite3", $writable);
}

sub dbh_new {
	my ($f, $writable) = @_;
	my $dbh = DBI->connect("dbi:SQLite:dbname=$f",'','', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		ReadOnly => !$writable,
		sqlite_use_immediate_transaction => 1,
	});
	$dbh->do('PRAGMA case_sensitive_like = ON');
	$dbh;
}

sub new_file {
	my ($class, $f, $writable) = @_;
	return if !$writable && !-r $f;

	my $dbh = dbh_new($f, $writable);
	my $self = bless { dbh => $dbh }, $class;

	if ($writable) {
		create_tables($dbh);
		$dbh->begin_work;
		$self->created_at(time) unless $self->created_at;
		$dbh->commit;
	}
	$self;
}

# used to keep track of used numeric mappings for v2 reindex
sub tmp_clone {
	my ($self) = @_;
	my ($fh, $fn) = tempfile('msgmap-XXXXXXXX', EXLOCK => 0, TMPDIR => 1);
	$self->{dbh}->sqlite_backup_to_file($fn);
	my $tmp = ref($self)->new_file($fn, 1);
	$tmp->{dbh}->do('PRAGMA synchronous = OFF');
	$tmp->{tmp_name} = $fn; # SQLite won't work if unlinked, apparently
	$tmp->{pid} = $$;
	close $fh or die "failed to close $fn: $!";
	$tmp;
}

# n.b. invoked directly by scripts/xhdr-num2mid
sub meta_accessor {
	my ($self, $key, $value) = @_;

	my $sql = 'SELECT val FROM meta WHERE key = ? LIMIT 1';
	my $dbh = $self->{dbh};
	my $prev;
	defined $value or return $dbh->selectrow_array($sql, undef, $key);

	$prev = $dbh->selectrow_array($sql, undef, $key);

	if (defined $prev) {
		$sql = 'UPDATE meta SET val = ? WHERE key = ? LIMIT 1';
		$dbh->do($sql, undef, $value, $key);
	} else {
		$sql = 'INSERT INTO meta (key,val) VALUES (?,?)';
		$dbh->do($sql, undef, $key, $value);
	}
	$prev;
}

sub last_commit {
	my ($self, $commit) = @_;
	$self->meta_accessor('last_commit', $commit);
}

sub last_commit_n {
	my ($self, $i, $commit) = @_;
	$self->meta_accessor('last_commit'.$i, $commit);
}

sub created_at {
	my ($self, $second) = @_;
	$self->meta_accessor('created_at', $second);
}

sub mid_insert {
	my ($self, $mid) = @_;
	my $dbh = $self->{dbh};
	my $sql = 'INSERT OR IGNORE INTO msgmap (mid) VALUES (?)';
	my $sth = $self->{mid_insert} ||= $dbh->prepare($sql);
	$sth->bind_param(1, $mid);
	return if $sth->execute == 0;
	$dbh->last_insert_id(undef, undef, 'msgmap', 'num');
}

sub mid_for {
	my ($self, $num) = @_;
	my $dbh = $self->{dbh};
	my $sth = $self->{mid_for} ||=
		$dbh->prepare('SELECT mid FROM msgmap WHERE num = ? LIMIT 1');
	$sth->bind_param(1, $num);
	$sth->execute;
	$sth->fetchrow_array;
}

sub num_for {
	my ($self, $mid) = @_;
	my $dbh = $self->{dbh};
	my $sth = $self->{num_for} ||=
		$dbh->prepare('SELECT num FROM msgmap WHERE mid = ? LIMIT 1');
	$sth->bind_param(1, $mid);
	$sth->execute;
	$sth->fetchrow_array;
}

sub minmax {
	my ($self) = @_;
	my $dbh = $self->{dbh};
	my $sth = $self->{num_minmax} ||=
		$dbh->prepare('SELECT MIN(num),MAX(num) FROM msgmap');
	$sth->execute;
        $sth->fetchrow_array;
}

sub mid_prefixes {
	my ($self, $pfx, $limit) = @_;

	die "No prefix given" unless (defined $pfx && $pfx ne '');
	$pfx =~ s/([%_])/\\$1/g;
	$pfx .= '%';

	$limit ||= 100;
	$limit += 0; # force to integer
	$limit ||= 100;

	$self->{dbh}->selectcol_arrayref('SELECT mid FROM msgmap ' .
					 'WHERE mid LIKE ? ESCAPE ? ' .
					 "ORDER BY num DESC LIMIT $limit",
					 undef, $pfx, '\\');
}

sub mid_delete {
	my ($self, $mid) = @_;
	my $dbh = $self->{dbh};
	my $sth = $dbh->prepare('DELETE FROM msgmap WHERE mid = ?');
	$sth->bind_param(1, $mid);
	$sth->execute;
}

sub num_delete {
	my ($self, $num) = @_;
	my $dbh = $self->{dbh};
	my $sth = $dbh->prepare('DELETE FROM msgmap WHERE num = ?');
	$sth->bind_param(1, $num);
	$sth->execute;
}

sub create_tables {
	my ($dbh) = @_;
	my $e;

	$e = eval { $dbh->selectrow_array('EXPLAIN SELECT * FROM msgmap;') };
	defined $e or $dbh->do('CREATE TABLE msgmap (' .
			'num INTEGER PRIMARY KEY AUTOINCREMENT, '.
			'mid VARCHAR(1000) NOT NULL, ' .
			'UNIQUE (mid) )');

	$e = eval { $dbh->selectrow_array('EXPLAIN SELECT * FROM meta') };
	defined $e or $dbh->do('CREATE TABLE meta (' .
			'key VARCHAR(32) PRIMARY KEY, '.
			'val VARCHAR(255) NOT NULL)');
}

# used by NNTP.pm
sub ids_after {
	my ($self, $num) = @_;
	my $ids = $self->{dbh}->selectcol_arrayref(<<'', undef, $$num);
SELECT num FROM msgmap WHERE num > ?
ORDER BY num ASC LIMIT 1000

	$$num = $ids->[-1] if @$ids;
	$ids;
}

sub msg_range {
	my ($self, $beg, $end) = @_;
	my $dbh = $self->{dbh};
	my $attr = { Columns => [] };
	my $mids = $dbh->selectall_arrayref(<<'', $attr, $$beg, $end);
SELECT num,mid FROM msgmap WHERE num >= ? AND num <= ?
ORDER BY num ASC

	$$beg = $mids->[-1]->[0] + 1 if @$mids;
	$mids
}

# only used for mapping external serial numbers (e.g. articles from gmane)
# see scripts/xhdr-num2mid or PublicInbox::Filter::RubyLang for usage
sub mid_set {
	my ($self, $num, $mid) = @_;
	my $sth = $self->{mid_set} ||= do {
		$self->{dbh}->prepare(
			'INSERT OR IGNORE INTO msgmap (num,mid) VALUES (?,?)');
	};
	$sth->execute($num, $mid);
}

sub DESTROY {
	my ($self) = @_;
	delete $self->{dbh};
	my $f = delete $self->{tmp_name};
	if (defined $f && $self->{pid} == $$) {
		unlink $f or warn "failed to unlink $f: $!\n";
	}
}

sub atfork_parent {
	my ($self) = @_;
	my $f = $self->{tmp_name} or die "not a temporary clone\n";
	delete $self->{dbh} and die "tmp_clone dbh not prepared for parent";
	my $dbh = $self->{dbh} = dbh_new($f, 1);
	$dbh->do('PRAGMA synchronous = OFF');
}

sub atfork_prepare {
	my ($self) = @_;
	my $f = $self->{tmp_name} or die "not a temporary clone\n";
	$self->{pid} == $$ or
		die "BUG: atfork_prepare not called from $self->{pid}\n";
	$self->{dbh} or die "temporary clone not open\n";
	# must clobber prepared statements
	%$self = (tmp_name => $f, pid => $$);
}

1;
