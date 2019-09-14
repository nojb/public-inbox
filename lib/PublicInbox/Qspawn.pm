# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Like most Perl modules in public-inbox, this is internal and
# NOT subject to any stability guarantees!  It is only documented
# for other hackers.
#
# This is used to limit the number of processes spawned by the
# PSGI server, so it acts like a semaphore and queues up extra
# commands to be run if currently at the limit.  Multiple "limiters"
# may be configured which give inboxes different channels to
# operate in.  This can be useful to ensure smaller inboxes can
# be cloned while cloning of large inboxes is maxed out.
#
# This does not depend on PublicInbox::DS or any other external
# scheduling mechanism, you just need to call start() and finish()
# appropriately. However, public-inbox-httpd (which uses PublicInbox::DS)
# will be able to schedule this based on readability of stdout from
# the spawned process.  See GitHTTPBackend.pm and SolverGit.pm for
# usage examples.  It does not depend on any form of threading.
#
# This is useful for scheduling CGI execution of both long-lived
# git-http-backend(1) process (for "git clone") as well as short-lived
# processes such as git-apply(1).

package PublicInbox::Qspawn;
use strict;
use warnings;
use PublicInbox::Spawn qw(popen_rd);
use POSIX qw(WNOHANG);
require Plack::Util;

# n.b.: we get EAGAIN with public-inbox-httpd, and EINTR on other PSGI servers
use Errno qw(EAGAIN EINTR);

my $def_limiter;

# declares a command to spawn (but does not spawn it).
# $cmd is the command to spawn
# $env is the environ for the child process
# $opt can include redirects and perhaps other process spawning options
sub new ($$$;) {
	my ($class, $cmd, $env, $opt) = @_;
	bless { args => [ $cmd, $env, $opt ] }, $class;
}

sub _do_spawn {
	my ($self, $cb) = @_;
	my $err;
	my ($cmd, $env, $opts) = @{$self->{args}};
	my %opts = %{$opts || {}};
	my $limiter = $self->{limiter};
	foreach my $k (PublicInbox::Spawn::RLIMITS()) {
		if (defined(my $rlimit = $limiter->{$k})) {
			$opts{$k} = $rlimit;
		}
	}

	($self->{rpipe}, $self->{pid}) = popen_rd($cmd, $env, \%opts);
	if (defined $self->{pid}) {
		$limiter->{running}++;
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

# callback for dwaitpid
sub waitpid_err ($$) {
	my ($self, $pid) = @_;
	my $xpid = delete $self->{pid};
	my $err;
	if ($pid > 0) { # success!
		$err = child_err($?);
	} elsif ($pid < 0) { # ??? does this happen in our case?
		$err = "W: waitpid($xpid, 0) => $pid: $!";
	} # else should not be called with pid == 0

	# done, spawn whatever's in the queue
	my $limiter = $self->{limiter};
	my $running = --$limiter->{running};

	# limiter->{max} may change dynamically
	if (($running || $limiter->{running}) < $limiter->{max}) {
		if (my $next = shift @{$limiter->{run_queue}}) {
			_do_spawn(@$next);
		}
	}

	return unless $err;
	$self->{err} = $err;
	my $env = $self->{env} or return;
	if (!$env->{'qspawn.quiet'}) {
		$err = join(' ', @{$self->{args}->[0]}).": $err\n";
		$env->{'psgi.errors'}->print($err);
	}
}

sub do_waitpid ($;$) {
	my ($self, $env) = @_;
	my $pid = $self->{pid};
	eval { # PublicInbox::DS may not be loaded
		PublicInbox::DS::dwaitpid($pid, \&waitpid_err, $self);
		$self->{env} = $env;
	};
	# done if we're running in PublicInbox::DS::EventLoop
	if ($@) {
		# non public-inbox-{httpd,nntpd} callers may block:
		my $ret = waitpid($pid, 0);
		waitpid_err($self, $ret);
	}
}

sub finish ($;$) {
	my ($self, $env) = @_;
	if (delete $self->{rpipe}) {
		do_waitpid($self, $env);
	}

	# limiter->{max} may change dynamically
	my $limiter = $self->{limiter};
	if ($limiter->{running} < $limiter->{max}) {
		if (my $next = shift @{$limiter->{run_queue}}) {
			_do_spawn(@$next);
		}
	}
	$self->{err}; # may be meaningless if non-blocking
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

# Similar to `backtick` or "qx" ("perldoc -f qx"), it calls $qx_cb with
# the stdout of the given command when done; but respects the given limiter
# $env is the PSGI env.  As with ``/qx; only use this when output is small
# and safe to slurp.
sub psgi_qx {
	my ($self, $env, $limiter, $qx_cb) = @_;
	my $scalar = '';
	open(my $qx, '+>', \$scalar) or die; # PerlIO::scalar
	my $end = sub {
		finish($self, $env);
		eval { $qx_cb->(\$scalar) };
		$qx = $scalar = undef;
	};
	my $rpipe; # comes from popen_rd
	my $async = $env->{'pi-httpd.async'};
	my $cb = sub {
		my $r = sysread($rpipe, my $buf, 65536);
		if ($async) {
			$async->async_pass($env->{'psgix.io'}, $qx, \$buf);
		} elsif (defined $r) {
			$r ? $qx->write($buf) : $end->();
		} else {
			return if $! == EAGAIN || $! == EINTR; # loop again
			$end->();
		}
	};
	$limiter ||= $def_limiter ||= PublicInbox::Qspawn::Limiter->new(32);
	$self->start($limiter, sub { # may run later, much later...
		($rpipe) = @_; # popen_rd result
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

# Used for streaming the stdout of one process as a PSGI response.
#
# $env is the PSGI env.
# optional keys in $env:
#   $env->{'qspawn.wcb'} - the write callback from the PSGI server
#                          optional, use this if you've already
#                          captured it elsewhere.  If not given,
#                          psgi_return will return an anonymous
#                          sub for the PSGI server to call
#
#   $env->{'qspawn.filter'} - filter callback, receives a string as input,
#                             undef on EOF
#
# $limiter - the Limiter object to use (uses the def_limiter if not given)
#
# $parse_hdr - Initial read function; often for parsing CGI header output.
#              It will be given the return value of sysread from the pipe
#              and a string ref of the current buffer.  Returns an arrayref
#              for PSGI responses.  2-element arrays in PSGI mean the
#              body will be streamed, later, via writes (push-based) to
#              psgix.io.  3-element arrays means the body is available
#              immediately (or streamed via ->getline (pull-based)).
sub psgi_return {
	my ($self, $env, $limiter, $parse_hdr) = @_;
	my ($fh, $rpipe);
	my $end = sub {
		finish($self, $env);
		$fh->close if $fh; # async-only
	};

	my $buf = '';
	my $rd_hdr = sub {
		# we must loop until EAGAIN for EPOLLET in HTTPD/Async.pm
		# We also need to check EINTR for generic PSGI servers.
		my $ret;
		my $n = 0;
		do {
			my $r = sysread($rpipe, $buf, 4096, length($buf));
			return if !defined($r) && $! == EAGAIN || $! == EINTR;

			# $r may be undef, here:
			$n += $r if $r;
			$ret = $parse_hdr->($r ? $n : $r, \$buf);
		} until (defined $ret);
		$ret;
	};

	my $wcb = delete $env->{'qspawn.wcb'};
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
			$wcb->($r);
		} elsif ($async) {
			$fh = $wcb->($r); # scalar @$r == 2
			$fh = filter_fh($fh, $filter) if $filter;
			$async->async_pass($env->{'psgix.io'}, $fh, \$buf);
		} else { # for synchronous PSGI servers
			require PublicInbox::GetlineBody;
			$r->[2] = PublicInbox::GetlineBody->new($rpipe, $end,
								$buf, $filter);
			$wcb->($r);
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

	# the caller already captured the PSGI write callback from
	# the PSGI server, so we can call ->start, here:
	return $self->start($limiter, $start_cb) if $wcb;

	# the caller will return this sub to the PSGI server, so
	# it can set the response callback (that is, for PublicInbox::HTTP,
	# the chunked_wcb or identity_wcb callback), but other HTTP servers
	# are supported:
	sub {
		($wcb) = @_;
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
		# RLIMIT_CPU => undef,
		# RLIMIT_DATA => undef,
		# RLIMIT_CORE => undef,
	}, $class;
}

sub setup_rlimit {
	my ($self, $name, $config) = @_;
	foreach my $rlim (PublicInbox::Spawn::RLIMITS()) {
		my $k = lc($rlim);
		$k =~ tr/_//d;
		$k = "publicinboxlimiter.$name.$k";
		defined(my $v = $config->{$k}) or next;
		my @rlimit = split(/\s*,\s*/, $v);
		if (scalar(@rlimit) == 1) {
			push @rlimit, $rlimit[0];
		} elsif (scalar(@rlimit) != 2) {
			warn "could not parse $k: $v\n";
		}
		eval { require BSD::Resource };
		if ($@) {
			warn "BSD::Resource missing for $rlim";
			next;
		}
		foreach my $i (0..$#rlimit) {
			next if $rlimit[$i] ne 'INFINITY';
			$rlimit[$i] = BSD::Resource::RLIM_INFINITY();
		}
		$self->{$rlim} = \@rlimit;
	}
}

1;
