# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD (currently a singleton),
# see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use parent qw(PublicInbox::NNTPD);

sub new {
	my ($class) = @_;
	$class->SUPER::new; # PublicInbox::NNTPD->new
}

1;
