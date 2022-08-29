# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Read-only external (detached) index for cross inbox search.
# This is a read-only counterpart to PublicInbox::ExtSearchIdx
# and behaves like PublicInbox::Inbox AND PublicInbox::Search
package PublicInbox::ExtSearch;
use strict;
use v5.10.1;
use PublicInbox::Over;
use PublicInbox::Inbox;
use PublicInbox::MiscSearch;
use DBI qw(:sql_types); # SQL_BLOB

# for ->reopen, ->mset, ->mset_to_artnums
use parent qw(PublicInbox::Search);

sub new {
	my ($class, $topdir) = @_;
	bless {
		topdir => $topdir,
		-primary_address => 'unknown@example.com',
		# xpfx => 'ei15'
		xpfx => "$topdir/ei".PublicInbox::Search::SCHEMA_VERSION
	}, $class;
}

sub misc {
	my ($self) = @_;
	$self->{misc} //= PublicInbox::MiscSearch->new("$self->{xpfx}/misc");
}

# same as per-inbox ->over, for now...
sub over {
	my ($self) = @_;
	$self->{over} //= do {
		PublicInbox::Inbox::_cleanup_later($self);
		PublicInbox::Over->new("$self->{xpfx}/over.sqlite3");
	};
}

sub git {
	my ($self) = @_;
	$self->{git} //= do {
		PublicInbox::Inbox::_cleanup_later($self);
		PublicInbox::Git->new("$self->{topdir}/ALL.git");
	};
}

# returns a hashref of { $NEWSGROUP_NAME => $ART_NO } using the `xref3' table
sub nntp_xref_for { # NNTP only
	my ($self, $xibx, $xsmsg) = @_;
	my $dbh = over($self)->dbh;

	my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT ibx_id FROM inboxes WHERE eidx_key = ? LIMIT 1

	$sth->execute($xibx->{newsgroup});
	my $xibx_id = $sth->fetchrow_array // do {
		warn "W: `$xibx->{newsgroup}' not found in $self->{topdir}\n";
		return;
	};

	$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT docid FROM xref3 WHERE oidbin = ? AND xnum = ? AND ibx_id = ? LIMIT 1

	$sth->bind_param(1, $xsmsg->oidbin, SQL_BLOB);

	# NNTP::cmd_over can set {num} to zero according to RFC 3977 8.3.2
	$sth->bind_param(2, $xsmsg->{num} || $xsmsg->{-orig_num});
	$sth->bind_param(3, $xibx_id);
	$sth->execute;
	my $docid = $sth->fetchrow_array // do {
		warn <<EOF;
W: `$xibx->{newsgroup}:$xsmsg->{num}' not found in $self->{topdir}"
EOF
		return;
	};

	# LIMIT is number of newsgroups on server:
	$sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT ibx_id,xnum FROM xref3 WHERE docid = ? AND ibx_id != ?

	$sth->execute($docid, $xibx_id);
	my $rows = $sth->fetchall_arrayref;

	my $eidx_key_sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT eidx_key FROM inboxes WHERE ibx_id = ? LIMIT 1

	my %xref = map {
		my ($ibx_id, $xnum) = @$_;

		$eidx_key_sth->execute($ibx_id);
		my $eidx_key = $eidx_key_sth->fetchrow_array;

		# only include if there's a newsgroup name
		$eidx_key && index($eidx_key, '/') >= 0 ?
			() : ($eidx_key => $xnum)
	} @$rows;
	$xref{$xibx->{newsgroup}} = $xsmsg->{num};
	\%xref;
}

sub mm { undef }

sub altid_map { {} }

sub description {
	my ($self) = @_;
	($self->{description} //=
		PublicInbox::Inbox::cat_desc("$self->{topdir}/description")) //
		'$EXTINDEX_DIR/description missing';
}

sub search {
	PublicInbox::Inbox::_cleanup_later($_[0]);
	$_[0];
}

sub thing_type { 'external index' }

no warnings 'once';
*base_url = \&PublicInbox::Inbox::base_url;
*smsg_eml = \&PublicInbox::Inbox::smsg_eml;
*smsg_by_mid = \&PublicInbox::Inbox::smsg_by_mid;
*msg_by_mid = \&PublicInbox::Inbox::msg_by_mid;
*modified = \&PublicInbox::Inbox::modified;

*max_git_epoch = *nntp_usable = *msg_by_path = \&mm; # undef
*isrch = \&search;

1;
