# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for XOVER, OVER in NNTP, and feeds/homepage/threads in PSGI
# Unlike Msgmap, this is an _UNSTABLE_ database which can be
# tweaked/updated over time and rebuilt.
package PublicInbox::Over;
use strict;
use warnings;
use DBI;
use DBD::SQLite;
use PublicInbox::SearchMsg;
use Compress::Zlib qw(uncompress);

sub dbh_new {
	my ($self) = @_;
	my $ro = ref($self) eq 'PublicInbox::Over';
	my $dbh = DBI->connect("dbi:SQLite:dbname=$self->{filename}",'','', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		ReadOnly => $ro,
		sqlite_use_immediate_transaction => 1,
	});
	$dbh->{sqlite_unicode} = 1;
	$dbh;
}

sub new {
	my ($class, $f) = @_;
	bless { filename => $f }, $class;
}

sub disconnect { $_[0]->{dbh} = undef }

sub connect { $_[0]->{dbh} ||= $_[0]->dbh_new }

sub load_from_row {
	my ($smsg) = @_;
	bless $smsg, 'PublicInbox::SearchMsg';
	if (defined(my $data = delete $smsg->{ddd})) {
		$data = uncompress($data);
		utf8::decode($data);
		$smsg->load_from_data($data);
	}
	$smsg
}

sub do_get {
	my ($self, $sql, $opts, @args) = @_;
	my $dbh = $self->connect;
	my $lim = (($opts->{limit} || 0) + 0) || 1000;
	my $off = (($opts->{offset} || 0) + 0) || 0;
	$sql .= "LIMIT $lim";
	$sql .= " OFFSET $off" if $off > 0;
	my $msgs = $dbh->selectall_arrayref($sql, { Slice => {} }, @args);
	load_from_row($_) for @$msgs;
	$msgs
}

sub query_xover {
	my ($self, $beg, $end) = @_;
	do_get($self, <<'', {}, $beg, $end);
SELECT * FROM over WHERE num >= ? AND num <= ?
ORDER BY num ASC

}

sub query_ts {
	my ($self, $ts, $prev) = @_;
	do_get($self, <<'', {}, $ts, $prev);
SELECT num,ddd FROM over WHERE ts >= ? AND num > ?
ORDER BY num ASC

}

sub nothing () { wantarray ? (0, []) : [] };

sub get_thread {
	my ($self, $mid, $opts) = @_;
	my $dbh = $self->connect;

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

	my $cond = 'FROM over WHERE (tid = ? OR sid = ?) AND num > 0';
	my $msgs = do_get($self, <<"", $opts, $tid, $sid);
SELECT * $cond ORDER BY ts ASC

	return $msgs unless wantarray;

	my $nr = $dbh->selectrow_array(<<"", undef, $tid, $sid);
SELECT COUNT(num) $cond

	($nr, $msgs);
}

sub recent {
	my ($self, $opts) = @_;
	my $msgs = do_get($self, <<'', $opts);
SELECT * FROM over WHERE num > 0
ORDER BY ts DESC

	return $msgs unless wantarray;

	my $nr = $self->{dbh}->selectrow_array(<<'');
SELECT COUNT(num) FROM over WHERE num > 0

	($nr, $msgs);
}

sub get_art {
	my ($self, $num) = @_;
	my $dbh = $self->connect;
	my $smsg = $dbh->selectrow_hashref(<<'', undef, $num);
SELECT * from OVER where num = ? LIMIT 1

	return load_from_row($smsg) if $smsg;
	undef;
}

1;
