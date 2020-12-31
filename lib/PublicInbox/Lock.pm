# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Base class for per-inbox locking
package PublicInbox::Lock;
use strict;
use v5.10.1;
use Fcntl qw(:flock :DEFAULT);
use Carp qw(croak);
use PublicInbox::OnDestroy;
use File::Temp ();

# we only acquire the flock if creating or reindexing;
# PublicInbox::Import already has the lock on its own.
sub lock_acquire {
	my ($self) = @_;
	my $lock_path = $self->{lock_path};
	croak 'already locked '.($lock_path // '(undef)') if $self->{lockfh};
	return unless defined($lock_path);
	sysopen(my $lockfh, $lock_path, O_WRONLY|O_CREAT) or
		croak "failed to open $lock_path: $!\n";
	flock($lockfh, LOCK_EX) or croak "lock $lock_path failed: $!\n";
	$self->{lockfh} = $lockfh;
}

sub lock_release {
	my ($self, $wake) = @_;
	defined(my $lock_path = $self->{lock_path}) or return;
	my $lockfh = delete $self->{lockfh} or croak "not locked: $lock_path";

	syswrite($lockfh, '.') if $wake;

	flock($lockfh, LOCK_UN) or croak "unlock $lock_path failed: $!\n";
	close $lockfh or croak "close $lock_path failed: $!\n";
}

# caller must use return value
sub lock_for_scope {
	my ($self, @single_pid) = @_;
	$self->lock_acquire;
	PublicInbox::OnDestroy->new(@single_pid, \&lock_release, $self);
}

sub new_tmp {
	my ($cls, $ident) = @_;
	my $tmp = File::Temp->new("$ident.lock-XXXXXX", TMPDIR => 1);
	bless { lock_path => $tmp->filename, tmp => $tmp }, $cls;
}

1;
