# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Read-only external (detached) index for cross inbox search.
# This is a read-only counterpart to PublicInbox::ExtSearchIdx
package PublicInbox::ExtSearch;
use strict;
use v5.10.1;
use PublicInbox::Over;

# for ->reopen, ->mset, ->mset_to_artnums
use parent qw(PublicInbox::Search);

sub new {
	my (undef, $topdir) = @_;
	bless {
		topdir => $topdir,
		# xpfx => 'ei15'
		xpfx => "$topdir/ei".PublicInbox::Search::SCHEMA_VERSION
	}, __PACKAGE__;
}

# overrides PublicInbox::Search::_xdb
sub _xdb {
	my ($self) = @_;
	$self->_xdb_sharded($self->{xpfx});
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

1;
