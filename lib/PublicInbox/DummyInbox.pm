# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# An EXAMINE-able, PublicInbox::Inbox-like object for IMAP.  Some
# IMAP clients don't like having unselectable parent mailboxes,
# so we have a dummy
package PublicInbox::DummyInbox;
use strict;

sub created_at { 0 } # Msgmap::created_at
sub mm { shift }
sub max { undef } # Msgmap::max
sub msg_range { [] } # Msgmap::msg_range

no warnings 'once';
*query_xover = \&msg_range;
*over = \&mm;
*subscribe_unlock = *unsubscribe_unlock =
	*get_art = *description = *base_url = \&max;

1;
