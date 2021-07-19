# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents a Maildir or IMAP "watch" item
package PublicInbox::LeiWatch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);

# "url" may be something like "maildir:/path/to/dir"
sub new { bless { url => $_[1] }, $_[0] }

1;
