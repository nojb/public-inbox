# Copyright (C) all contributors <meta@public-inbox.org>
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
# This does not depend on the PublicInbox::DS::event_loop or any
# other external scheduling mechanism, you just need to call
# start() and finish() appropriately. However, public-inbox-httpd
# (which uses PublicInbox::DS)  will be able to schedule this
# based on readability of stdout from the spawned process.
# See GitHTTPBackend.pm and SolverGit.pm for usage examples.
# It does not depend on any form of threading.
#
# This is useful for scheduling CGI execution of both long-lived
# git-http-backend(1) process (for "git clone") as well as short-lived
# processes such as git-apply(1).

package PublicInbox::Qspawn;
use strict;
use v5.10.1;
use PublicInbox::Spawn qw(popen_rd);
use PublicInbox::GzipFilter;

# n.b.: we get EAGAIN with public-inbox-httpd, and EINTR on other PSGI servers
use Errno qw(EAGAIN EINTR);

my $def_limiter;

# declares a command to spawn (but does not spawn it).
# $cmd is the command to spawn
# $cmd_env is the environ for the child process (not PSGI env)
# $opt can include redirects and perhaps other process spawning options
# {qsp_err} is an optional error buffer callers may access themselves
sub new ($$$;) {
	my ($class, $cmd, $cmd_env, $opt) = @_;
	bless { args => [ $cmd, $cmd_env, $opt ] }, $class;
}

sub _do_spawn {
	my ($self, $start_cb, $limiter) = @_;
	my $err;
	my ($cmd, $cmd_env, $opt) = @{delete $self->{args}};
	my %o = %{$opt || {}};
	$self->{limiter} = $limiter;
	foreach my $k (@PublicInbox::Spawn::RLIMITS) {
		if (defined(my $rlimit = $limiter->{$k})) {
			$o{$k} = $rlimit;
		}
	}
	$self->{cmd} = $o{quiet} ? undef : $cmd;
	eval {
		# popen_rd may die on EMFILE, ENFILE
		$self->{rpipe} = popen_rd($cmd, $cmd_env, \%o);

		die "E: $!" unless defined($self->{rpipe});

		$limiter->{running}++;
		$start_cb->($self); # EPOLL_CTL_ADD may ENOSPC/ENOMEM
	};
	finish($self, $@) if $@;
}

sub child_err ($) {
	my ($child_error) = @_; # typically $?
	my $exitstatus = ($child_error >> 8) or return;
	my $sig = $child_error & 127;
	my $msg = "exit status=$exitstatus";
	$msg .= " signal=$sig" if $sig;
	$msg;
}

sub finalize ($$) {
	my ($self, $err) = @_;

	my ($env, $qx_cb, $qx_arg, $qx_buf) =
		delete @$self{qw(psgi_env qx_cb qx_arg qx_buf)};

	# done, spawn whatever's in the queue
	my $limiter = $self->{limiter};
	my $running = --$limiter->{running};

	if ($running < $limiter->{max}) {
		if (my $next = shift(@{$limiter->{run_queue}})) {
			_do_spawn(@$next, $limiter);
		}
	}

	if ($err) {
		utf8::decode($err);
		if (my $dst = $self->{qsp_err}) {
			$$dst .= $$dst ? " $err" : "; $err";
		}
		warn "@{$self->{cmd}}: $err" if $self->{cmd};
	}
	if ($qx_cb) {
		eval { $qx_cb->($qx_buf, $qx_arg) };
		return unless $@;
		warn "E: $@"; # hope qspawn.wcb can handle it
	}
	if (my $wcb = delete $env->{'qspawn.wcb'}) {
		# have we started writing, yet?
		require PublicInbox::WwwStatic;
		$wcb->(PublicInbox::WwwStatic::r(500));
	}
}

# callback for dwaitpid or ProcessPipe
sub waitpid_err { finalize($_[0], child_err($?)) }

sub finish ($;$) {
	my ($self, $err) = @_;
	my $tied_pp = delete($self->{rpipe}) or return finalize($self, $err);
	my PublicInbox::ProcessPipe $pp = tied *$tied_pp;
	@$pp{qw(cb arg)} = (\&waitpid_err, $self); # for ->DESTROY
}

sub start ($$$) {
	my ($self, $limiter, $start_cb) = @_;
	if ($limiter->{running} < $limiter->{max}) {
		_do_spawn($self, $start_cb, $limiter);
	} else {
		push @{$limiter->{run_queue}}, [ $self, $start_cb ];
	}
}

sub psgi_qx_init_cb {
	my ($self) = @_;
	my $async = delete $self->{async}; # PublicInbox::HTTPD::Async
	my ($r, $buf);
	my $qx_fh = $self->{qx_fh};
reread:
	$r = sysread($self->{rpipe}, $buf, 65536);
	if ($async) {
		$async->async_pass($self->{psgi_env}->{'psgix.io'},
					$qx_fh, \$buf);
	} elsif (defined $r) {
		$r ? (print $qx_fh $buf) : event_step($self, undef);
	} else {
		return if $! == EAGAIN; # try again when notified
		goto reread if $! == EINTR;
		event_step($self, $!);
	}
}

sub psgi_qx_start {
	my ($self) = @_;
	if (my $async = $self->{psgi_env}->{'pi-httpd.async'}) {
		# PublicInbox::HTTPD::Async->new(rpipe, $cb, cb_arg, $end_obj)
		$self->{async} = $async->($self->{rpipe},
					\&psgi_qx_init_cb, $self, $self);
		# init_cb will call ->async_pass or ->close
	} else { # generic PSGI
		psgi_qx_init_cb($self) while $self->{qx_fh};
	}
}

# Similar to `backtick` or "qx" ("perldoc -f qx"), it calls $qx_cb with
# the stdout of the given command when done; but respects the given limiter
# $env is the PSGI env.  As with ``/qx; only use this when output is small
# and safe to slurp.
sub psgi_qx {
	my ($self, $env, $limiter, $qx_cb, $qx_arg) = @_;
	$self->{psgi_env} = $env;
	my $qx_buf = '';
	open(my $qx_fh, '+>', \$qx_buf) or die; # PerlIO::scalar
	$self->{qx_cb} = $qx_cb;
	$self->{qx_arg} = $qx_arg;
	$self->{qx_fh} = $qx_fh;
	$self->{qx_buf} = \$qx_buf;
	$limiter ||= $def_limiter ||= PublicInbox::Qspawn::Limiter->new(32);
	start($self, $limiter, \&psgi_qx_start);
}

# this is called on pipe EOF to reap the process, may be called
# via PublicInbox::DS event loop OR via GetlineBody for generic
# PSGI servers.
sub event_step {
	my ($self, $err) = @_; # $err: $!
	warn "psgi_{return,qx} $err" if defined($err);
	finish($self);
	my ($fh, $qx_fh) = delete(@$self{qw(fh qx_fh)});
	$fh->close if $fh; # async-only (psgi_return)
}

sub rd_hdr ($) {
	my ($self) = @_;
	# typically used for reading CGI headers
	# We also need to check EINTR for generic PSGI servers.
	my $ret;
	my $total_rd = 0;
	my $hdr_buf = $self->{hdr_buf};
	my ($ph_cb, $ph_arg) = @{$self->{parse_hdr}};
	do {
		my $r = sysread($self->{rpipe}, $$hdr_buf, 4096,
				length($$hdr_buf));
		if (defined($r)) {
			$total_rd += $r;
			eval { $ret = $ph_cb->($total_rd, $hdr_buf, $ph_arg) };
			if ($@) {
				warn "parse_hdr: $@";
				$ret = [ 500, [], [ "Internal error\n" ] ];
			}
		} else {
			# caller should notify us when it's ready:
			return if $! == EAGAIN;
			next if $! == EINTR; # immediate retry
			warn "error reading header: $!";
			$ret = [ 500, [], [ "Internal error\n" ] ];
		}
	} until (defined $ret);
	delete $self->{parse_hdr}; # done parsing headers
	$ret;
}

sub psgi_return_init_cb {
	my ($self) = @_;
	my $r = rd_hdr($self) or return;
	my $env = $self->{psgi_env};
	my $filter = delete $env->{'qspawn.filter'} //
		PublicInbox::GzipFilter::qsp_maybe($r->[1], $env);

	my $wcb = delete $env->{'qspawn.wcb'};
	my $async = delete $self->{async}; # PublicInbox::HTTPD::Async
	if (scalar(@$r) == 3) { # error
		if ($async) { # calls rpipe->close && ->event_step
			$async->close; # PublicInbox::HTTPD::Async::close
		} else {
			$self->{rpipe}->close;
			event_step($self);
		}
		$wcb->($r);
	} elsif ($async) {
		# done reading headers, handoff to read body
		my $fh = $wcb->($r); # scalar @$r == 2
		$fh = $filter->attach($fh) if $filter;
		$self->{fh} = $fh;
		$async->async_pass($env->{'psgix.io'}, $fh,
					delete($self->{hdr_buf}));
	} else { # for synchronous PSGI servers
		require PublicInbox::GetlineBody;
		$r->[2] = PublicInbox::GetlineBody->new($self->{rpipe},
					\&event_step, $self,
					${$self->{hdr_buf}}, $filter);
		$wcb->($r);
	}
}

sub psgi_return_start { # may run later, much later...
	my ($self) = @_;
	if (my $cb = $self->{psgi_env}->{'pi-httpd.async'}) {
		# PublicInbox::HTTPD::Async->new(rpipe, $cb, $cb_arg, $end_obj)
		$self->{async} = $cb->($self->{rpipe},
					\&psgi_return_init_cb, $self, $self);
	} else { # generic PSGI
		psgi_return_init_cb($self) while $self->{parse_hdr};
	}
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
#   $env->{'qspawn.filter'} - filter object, responds to ->attach for
#                             pi-httpd.async and ->translate for generic
#                             PSGI servers
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
	my ($self, $env, $limiter, $parse_hdr, $hdr_arg) = @_;
	$self->{psgi_env} = $env;
	$self->{hdr_buf} = \(my $hdr_buf = '');
	$self->{parse_hdr} = [ $parse_hdr, $hdr_arg ];
	$limiter ||= $def_limiter ||= PublicInbox::Qspawn::Limiter->new(32);

	# the caller already captured the PSGI write callback from
	# the PSGI server, so we can call ->start, here:
	$env->{'qspawn.wcb'} and
		return start($self, $limiter, \&psgi_return_start);

	# the caller will return this sub to the PSGI server, so
	# it can set the response callback (that is, for
	# PublicInbox::HTTP, the chunked_wcb or identity_wcb callback),
	# but other HTTP servers are supported:
	sub {
		$env->{'qspawn.wcb'} = $_[0];
		start($self, $limiter, \&psgi_return_start);
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
		# RLIMIT_CPU => undef,
		# RLIMIT_DATA => undef,
		# RLIMIT_CORE => undef,
	}, $class;
}

sub setup_rlimit {
	my ($self, $name, $cfg) = @_;
	foreach my $rlim (@PublicInbox::Spawn::RLIMITS) {
		my $k = lc($rlim);
		$k =~ tr/_//d;
		$k = "publicinboxlimiter.$name.$k";
		defined(my $v = $cfg->{$k}) or next;
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
