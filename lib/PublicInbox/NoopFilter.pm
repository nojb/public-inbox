# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::NoopFilter;
use strict;

sub new { bless \(my $self = ''), __PACKAGE__ }

# noop workalike for PublicInbox::GzipFilter methods
sub translate {
	my $self = $_[0];
	my $ret = $$self .= ($_[1] // '');
	$$self = '';
	$ret;
}

sub zmore {
	${$_[0]} .= $_[1];
	undef;
}

sub zflush { translate($_[0], $_[1]) }

1;
