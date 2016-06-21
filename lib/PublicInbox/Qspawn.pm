# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Qspawn;
use strict;
use warnings;
use PublicInbox::Spawn qw(popen_rd);
our $LIMIT = 1;
my $running = 0;
my @run_queue;

sub new ($$$;) {
	my ($class, $cmd, $env, $opt) = @_;
	bless { args => [ $cmd, $env, $opt ] }, $class;
}

sub _do_spawn {
	my ($self, $cb) = @_;
	my $err;
	($self->{rpipe}, $self->{pid}) = popen_rd(@{$self->{args}});
	if (defined $self->{pid}) {
		$running++;
	} else {
		$self->{err} = $!;
	}
	$cb->($self->{rpipe});
}

sub finish ($) {
	my ($self) = @_;
	if (delete $self->{rpipe}) {
		my $pid = delete $self->{pid};
		$self->{err} = $pid == waitpid($pid, 0) ? $? :
				"PID:$pid still running?";
		$running--;
	}
	if (my $next = shift @run_queue) {
		_do_spawn(@$next);
	}
	$self->{err};
}

sub start ($$) {
	my ($self, $cb) = @_;

	if ($running < $LIMIT) {
		_do_spawn($self, $cb);
	} else {
		push @run_queue, [ $self, $cb ];
	}
}

1;
