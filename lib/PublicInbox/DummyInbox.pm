# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# An EXAMINE-able, PublicInbox::Inbox-like object for IMAP.  Some
# IMAP clients don't like having unselectable parent mailboxes,
# so we have a dummy
package PublicInbox::DummyInbox;
use strict;

sub uidvalidity { 0 } # Msgmap::created_at
sub mm { shift }
sub uid_range { [] } # Over::uid_range
sub subscribe_unlock { undef };

no warnings 'once';
*max = \&uidvalidity;
*query_xover = \&uid_range;
*over = \&mm;
*search = *unsubscribe_unlock =
	*get_art = *description = *base_url = \&subscribe_unlock;

1;
