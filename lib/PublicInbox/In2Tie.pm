# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used to ensure PublicInbox::DS can call fileno() as a function
# on Linux::Inotify2 objects
package PublicInbox::In2Tie;
use strict;

sub TIEHANDLE {
	my ($class, $in2) = @_;
	bless \$in2, $class; # a scalar reference to an existing reference
}

# this calls Linux::Inotify2::fileno
sub FILENO { ${$_[0]}->fileno }

1;
