# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used to ensure PublicInbox::DS can call fileno() as a function
# on Linux::Inotify2 objects
package PublicInbox::In2Tie;
use strict;
use Symbol qw(gensym);

sub io {
	my $in2 = $_[0];
	$in2->blocking(0);
	if ($in2->can('on_overflow')) {
		# broadcasts everything on overflow
		$in2->on_overflow(undef);
	}
	my $io = gensym;
	tie *$io, __PACKAGE__, $in2;
	$io;
}

sub TIEHANDLE {
	my ($class, $in2) = @_;
	bless \$in2, $class; # a scalar reference to an existing reference
}

# this calls Linux::Inotify2::fileno
sub FILENO { ${$_[0]}->fileno }

1;
