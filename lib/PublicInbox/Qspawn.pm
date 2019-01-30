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
require Plack::Util;
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

sub child_err ($) {
	my ($child_error) = @_; # typically $?
	my $exitstatus = ($child_error >> 8) or return;
	my $sig = $child_error & 127;
	my $msg = "exit status=$exitstatus";
	$msg .= " signal=$sig" if $sig;
	$msg;
}

sub finish ($) {
	my ($self) = @_;
	my $limiter = $self->{limiter};
	my $running;
	if (delete $self->{rpipe}) {
		my $pid = delete $self->{pid};
		$self->{err} = $pid == waitpid($pid, 0) ? child_err($?) :
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

sub _psgi_finish ($$) {
	my ($self, $env) = @_;
	my $err = $self->finish;
	if ($err && !$env->{'qspawn.quiet'}) {
		$err = join(' ', @{$self->{args}->[0]}).": $err\n";
		$env->{'psgi.errors'}->print($err);
	}
}

sub psgi_qx {
	my ($self, $env, $limiter, $qx_cb) = @_;
	my $qx = PublicInbox::Qspawn::Qx->new;
	my $end = sub {
		_psgi_finish($self, $env);
		eval { $qx_cb->($qx) };
		$qx = undef;
	};
	my $rpipe;
	my $async = $env->{'pi-httpd.async'};
	my $cb = sub {
		my $r = sysread($rpipe, my $buf, 8192);
		if ($async) {
			$async->async_pass($env->{'psgix.io'}, $qx, \$buf);
		} elsif (defined $r) {
			$r ? $qx->write($buf) : $end->();
		} else {
			return if $!{EAGAIN} || $!{EINTR}; # loop again
			$end->();
		}
	};
	$limiter ||= $def_limiter ||= PublicInbox::Qspawn::Limiter->new(32);
	$self->start($limiter, sub { # may run later, much later...
		($rpipe) = @_;
		if ($async) {
		# PublicInbox::HTTPD::Async->new($rpipe, $cb, $end)
			$async = $async->($rpipe, $cb, $end);
		} else { # generic PSGI
			$cb->() while $qx;
		}
	});
}

# create a filter for "push"-based streaming PSGI writes used by HTTPD::Async
sub filter_fh ($$) {
	my ($fh, $filter) = @_;
	Plack::Util::inline_object(
		close => sub {
			$fh->write($filter->(undef));
			$fh->close;
		},
		write => sub {
			$fh->write($filter->($_[0]));
		});
}

sub psgi_return {
	my ($self, $env, $limiter, $parse_hdr) = @_;
	my ($fh, $rpipe);
	my $end = sub {
		_psgi_finish($self, $env);
		$fh->close if $fh; # async-only
	};

	my $buf = '';
	my $rd_hdr = sub {
		my $r = sysread($rpipe, $buf, 1024, length($buf));
		return if !defined($r) && ($!{EINTR} || $!{EAGAIN});
		$parse_hdr->($r, \$buf);
	};
	my $res = delete $env->{'qspawn.response'};
	my $async = $env->{'pi-httpd.async'};
	my $cb = sub {
		my $r = $rd_hdr->() or return;
		$rd_hdr = undef;
		my $filter = delete $env->{'qspawn.filter'};
		if (scalar(@$r) == 3) { # error
			if ($async) {
				$async->close; # calls rpipe->close and $end
			} else {
				$rpipe->close;
				$end->();
			}
			$res->($r);
		} elsif ($async) {
			$fh = $res->($r); # scalar @$r == 2
			$fh = filter_fh($fh, $filter) if $filter;
			$async->async_pass($env->{'psgix.io'}, $fh, \$buf);
		} else { # for synchronous PSGI servers
			require PublicInbox::GetlineBody;
			$r->[2] = PublicInbox::GetlineBody->new($rpipe, $end,
								$buf, $filter);
			$res->($r);
		}
	};
	$limiter ||= $def_limiter ||= PublicInbox::Qspawn::Limiter->new(32);
	my $start_cb = sub { # may run later, much later...
		($rpipe) = @_;
		if ($async) {
			# PublicInbox::HTTPD::Async->new($rpipe, $cb, $end)
			$async = $async->($rpipe, $cb, $end);
		} else { # generic PSGI
			$cb->() while $rd_hdr;
		}
	};

	return $self->start($limiter, $start_cb) if $res;

	sub {
		($res) = @_;
		$self->start($limiter, $start_cb);
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

# captures everything into a buffer and executes a callback when done
package PublicInbox::Qspawn::Qx;
use strict;
use warnings;

sub new {
	my ($class) = @_;
	my $buf = '';
	bless \$buf, $class;
}

# called by PublicInbox::HTTPD::Async ($fh->write)
sub write {
	${$_[0]} .= $_[1];
	undef;
}

1;
