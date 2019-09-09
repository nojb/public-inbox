# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Base class for per-inbox locking
package PublicInbox::Lock;
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT);
use Carp qw(croak);

# we only acquire the flock if creating or reindexing;
# PublicInbox::Import already has the lock on its own.
sub lock_acquire {
	my ($self) = @_;
	croak 'already locked' if $self->{lockfh};
	my $lock_path = $self->{lock_path} or return;
	sysopen(my $lockfh, $lock_path, O_WRONLY|O_CREAT) or
		die "failed to open lock $lock_path: $!\n";
	flock($lockfh, LOCK_EX) or die "lock failed: $!\n";
	$self->{lockfh} = $lockfh;
}

sub lock_release {
	my ($self) = @_;
	return unless $self->{lock_path};
	my $lockfh = delete $self->{lockfh} or croak 'not locked';
	flock($lockfh, LOCK_UN) or die "unlock failed: $!\n";
	close $lockfh or die "close failed: $!\n";
}

1;
