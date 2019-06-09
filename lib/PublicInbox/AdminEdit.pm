# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common stuff between -edit, -purge (and maybe -learn in the future)
package PublicInbox::AdminEdit;
use strict;
use warnings;
use PublicInbox::Admin;
our @OPT = qw(all force|f verbose|v!);

1;
