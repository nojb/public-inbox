# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# automatically kill + reap children when this goes out-of-scope
package PublicInbox::AutoReap;
use v5.10.1;
use strict;

sub new {
	my (undef, $pid, $cb) = @_;
	bless { pid => $pid, cb => $cb, owner => $$ }, __PACKAGE__
}

sub kill {
	my ($self, $sig) = @_;
	CORE::kill($sig // 'TERM', $self->{pid});
}

sub join {
	my ($self, $sig) = @_;
	my $pid = delete $self->{pid} or return;
	$self->{cb}->() if defined $self->{cb};
	CORE::kill($sig, $pid) if defined $sig;
	my $ret = waitpid($pid, 0) // die "waitpid($pid): $!";
	$ret == $pid or die "BUG: waitpid($pid) != $ret";
}

sub DESTROY {
	my ($self) = @_;
	return if $self->{owner} != $$;
	$self->join('TERM');
}

1;
