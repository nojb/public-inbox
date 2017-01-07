# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Limits the number of processes spawned
# This does not depend on Danga::Socket or any other external
# scheduling mechanism, you just need to call start and finish
# appropriately
package PublicInbox::Qspawn;
use strict;
use warnings;
use PublicInbox::Spawn qw(popen_rd);

sub new ($$$;) {
	my ($class, $cmd, $env, $opt) = @_;
	bless { args => [ $cmd, $env, $opt ] }, $class;
}

sub _do_spawn {
	my ($self, $cb) = @_;
	my $err;

	($self->{rpipe}, $self->{pid}) = popen_rd(@{$self->{args}});
	if (defined $self->{pid}) {
		$self->{limiter}->{running}++;
	} else {
		$self->{err} = $!;
	}
	$cb->($self->{rpipe});
}

sub finish ($) {
	my ($self) = @_;
	my $limiter = $self->{limiter};
	my $running;
	if (delete $self->{rpipe}) {
		my $pid = delete $self->{pid};
		$self->{err} = $pid == waitpid($pid, 0) ? $? :
				"PID:$pid still running?";
		$running = --$limiter->{running};
	}

	# limiter->{max} may change dynamically
	if (($running || $limiter->{running}) < $limiter->{max}) {
		if (my $next = shift @{$limiter->{run_queue}}) {
			_do_spawn(@$next);
		}
	}
	$self->{err};
}

sub start {
	my ($self, $limiter, $cb) = @_;
	$self->{limiter} = $limiter;

	if ($limiter->{running} < $limiter->{max}) {
		_do_spawn($self, $cb);
	} else {
		push @{$limiter->{run_queue}}, [ $self, $cb ];
	}
}

package PublicInbox::Qspawn::Limiter;
use strict;
use warnings;

sub new {
	my ($class, $max) = @_;
	bless {
		# 32 is same as the git-daemon connection limit
		max => $max || 32,
		running => 0,
		run_queue => [],
	}, $class;
}

1;
