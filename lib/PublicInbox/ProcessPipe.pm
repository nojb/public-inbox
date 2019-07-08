# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# a tied handle for auto reaping of children tied to a pipe, see perltie(1)
package PublicInbox::ProcessPipe;
use strict;
use warnings;

sub TIEHANDLE {
	my ($class, $pid, $fh) = @_;
	bless { pid => $pid, fh => $fh }, $class;
}

sub READ { read($_[0]->{fh}, $_[1], $_[2], $_[3] || 0) }

sub READLINE { readline($_[0]->{fh}) }

sub CLOSE {
	my $fh = delete($_[0]->{fh});
	my $ret = defined $fh ? close($fh) : '';
	my $pid = delete $_[0]->{pid};
	if (defined $pid) {
		# PublicInbox::DS may not be loaded
		eval { PublicInbox::DS::dwaitpid($pid, undef, undef) };

		if ($@) { # ok, not in the event loop, work synchronously
			waitpid($pid, 0);
			$ret = '' if $?;
		}
	}
	$ret;
}

sub FILENO { fileno($_[0]->{fh}) }

sub DESTROY {
	CLOSE(@_);
	undef;
}

sub pid { $_[0]->{pid} }

1;
