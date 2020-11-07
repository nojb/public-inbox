# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Read-only external (detached) index for cross inbox search.
# This is a read-only counterpart to PublicInbox::ExtSearchIdx
# and behaves like PublicInbox::Inbox AND PublicInbox::Search
package PublicInbox::ExtSearch;
use strict;
use v5.10.1;
use PublicInbox::Over;
use PublicInbox::Inbox;
use File::Spec ();

# for ->reopen, ->mset, ->mset_to_artnums
use parent qw(PublicInbox::Search);

sub new {
	my (undef, $topdir) = @_;
	$topdir = File::Spec->canonpath($topdir);
	bless {
		topdir => $topdir,
		# xpfx => 'ei15'
		xpfx => "$topdir/ei".PublicInbox::Search::SCHEMA_VERSION
	}, __PACKAGE__;
}

sub search { $_[0] } # self

# overrides PublicInbox::Search::_xdb
sub _xdb {
	my ($self) = @_;
	$self->xdb_sharded;
}

# same as per-inbox ->over, for now...
sub over {
	my ($self) = @_;
	$self->{over} //= PublicInbox::Over->new("$self->{xpfx}/over.sqlite3");
}

sub git {
	my ($self) = @_;
	$self->{git} //= PublicInbox::Git->new("$self->{topdir}/ALL.git");
}

sub mm { undef }

sub altid_map { {} }

sub description {
	my ($self) = @_;
	($self->{description} //=
		PublicInbox::Inbox::cat_desc("$self->{topdir}/description")) //
		'$EINDEX_DIR/description missing';
}

sub cloneurl { [] } # TODO

sub base_url { 'https://example.com/TODO/' }
sub nntp_url { [] }

no warnings 'once';
*smsg_eml = \&PublicInbox::Inbox::smsg_eml;
*smsg_by_mid = \&PublicInbox::Inbox::smsg_by_mid;
*msg_by_mid = \&PublicInbox::Inbox::msg_by_mid;
*modified = \&PublicInbox::Inbox::modified;
*recent = \&PublicInbox::Inbox::recent;

*max_git_epoch = *nntp_usable = *msg_by_path = \&mm; # undef

1;
