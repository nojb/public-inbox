# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Limits the number of processes spawned
# This does not depend on Danga::Socket or any other external
# scheduling mechanism, you just need to call start and finish
# appropriately
package PublicInbox::Qspawn;
use strict;
use warnings;
use PublicInbox::Spawn qw(popen_rd);
my $def_limiter;

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

sub psgi_return {
	my ($self, $env, $limiter, $parse_hdr) = @_;
	my ($fh, $rpipe);
	my $end = sub {
		if (my $err = $self->finish) {
			$err = join(' ', @{$self->{args}->[0]}).": $err\n";
			$env->{'psgi.errors'}->print($err);
		}
		$fh->close if $fh; # async-only
	};

	# Danga::Socket users, we queue up the read_enable callback to
	# fire after pending writes are complete:
	my $buf = '';
	my $rd_hdr = sub {
		my $r = sysread($rpipe, $buf, 1024, length($buf));
		return if !defined($r) && ($!{EINTR} || $!{EAGAIN});
		$parse_hdr->($r, \$buf);
	};
	my $res;
	my $async = $env->{'pi-httpd.async'};
	my $cb = sub {
		my $r = $rd_hdr->() or return;
		$rd_hdr = undef;
		if (scalar(@$r) == 3) { # error
			if ($async) {
				$async->close; # calls rpipe->close
			} else {
				$rpipe->close;
				$end->();
			}
			$res->($r);
		} elsif ($async) {
			$fh = $res->($r); # scalar @$r == 2
			$async->async_pass($env->{'psgix.io'}, $fh, \$buf);
		} else { # for synchronous PSGI servers
			require PublicInbox::GetlineBody;
			$r->[2] = PublicInbox::GetlineBody->new($rpipe, $end,
								$buf);
			$res->($r);
		}
	};
	$limiter ||= $def_limiter ||= PublicInbox::Qspawn::Limiter->new(32);
	sub {
		($res) = @_;
		$self->start($limiter, sub { # may run later, much later...
			($rpipe) = @_;
			if ($async) {
			# PublicInbox::HTTPD::Async->new($rpipe, $cb, $end)
				$async = $async->($rpipe, $cb, $end);
			} else { # generic PSGI
				$cb->() while $rd_hdr;
			}
		});
	};
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
