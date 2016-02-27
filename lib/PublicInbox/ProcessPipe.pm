# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# a tied handle for auto reaping of children tied to a pipe, see perltie(1)
package PublicInbox::ProcessPipe;
use strict;
use warnings;

sub TIEHANDLE {
	my ($class, $pid, $fh) = @_;
	bless { pid => $pid, fh => $fh }, $class;
}

sub READ { sysread($_[0]->{fh}, $_[1], $_[2], $_[3] || 0) }

sub READLINE { readline($_[0]->{fh}) }

sub CLOSE { close($_[0]->{fh}) }

sub FILENO { fileno($_[0]->{fh}) }

sub DESTROY {
	my $fh = delete($_[0]->{fh});
	close $fh if $fh;
	waitpid($_[0]->{pid}, 0);
}

sub pid { $_[0]->{pid} }

1;
