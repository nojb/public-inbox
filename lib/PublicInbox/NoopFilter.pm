# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::NoopFilter;
use strict;

sub new { bless \(my $ignore), __PACKAGE__ }

# noop workalike for PublicInbox::GzipFilter methods
sub translate { $_[1] // '' }
sub zmore { $_[1] }
sub zflush { $_[1] // '' }
1;
