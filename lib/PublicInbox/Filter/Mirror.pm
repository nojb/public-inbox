# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Dumb filter for blindly accepting everything
package PublicInbox::Filter::Mirror;
use base qw(PublicInbox::Filter::Base);
use strict;
use warnings;

sub delivery { $_[0]->ACCEPT };

1;
