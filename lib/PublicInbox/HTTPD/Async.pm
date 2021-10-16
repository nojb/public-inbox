# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# XXX This is a totally unstable API for public-inbox internal use only
# This is exposed via the 'pi-httpd.async' key in the PSGI env hash.
# The name of this key is not even stable!
# Currently intended for use with read-only pipes with expensive
# processes such as git-http-backend(1), cgit(1)
#
# fields:
# http: PublicInbox::HTTP ref
# fh: PublicInbox::HTTP::{Identity,Chunked} ref (can ->write + ->close)
# cb: initial read callback
# arg: arg for {cb}
# end_obj: CODE or object which responds to ->event_step when ->close is called
package PublicInbox::HTTPD::Async;
use strict;
use parent qw(PublicInbox::DS);
use Errno qw(EAGAIN);
use PublicInbox::Syscall qw(EPOLLIN);

# This is called via: $env->{'pi-httpd.async'}->()
# $io is a read-only pipe ($rpipe) for now, but may be a
# bidirectional socket in the future.
sub new {
	my ($class, $io, $cb, $arg, $end_obj) = @_;

	# no $io? call $cb at the top of the next event loop to
	# avoid recursion:
	unless (defined($io)) {
		PublicInbox::DS::requeue($cb ? $cb : $arg);
		die '$end_obj unsupported w/o $io' if $end_obj;
		return;
	}
	my $self = bless {
		cb => $cb, # initial read callback
		arg => $arg, # arg for $cb
		end_obj => $end_obj, # like END{}, can ->event_step
	}, $class;
	my $pp = tied *$io;
	$pp->{fh}->blocking(0) // die "$io->blocking(0): $!";
	$self->SUPER::new($io, EPOLLIN);
}

sub event_step {
	my ($self) = @_;
	if (my $cb = delete $self->{cb}) {
		# this may call async_pass when headers are done
		$cb->(my $refcnt_guard = delete $self->{arg});
	} elsif (my $sock = $self->{sock}) {
		my $http = $self->{http};
		# $self->{sock} is a read pipe for git-http-backend or cgit
		# and 65536 is the default Linux pipe size
		my $r = sysread($sock, my $buf, 65536);
		if ($r) {
			$self->{fh}->write($buf); # may call $http->close
			# let other clients get some work done, too
			return if $http->{sock}; # !closed

			# else: fall through to close below...
		} elsif (!defined $r && $! == EAGAIN) {
			return; # EPOLLIN means we'll be notified
		}

		# Done! Error handling will happen in $self->{fh}->close
		# called by end_obj->event_step handler
		delete $http->{forward};
		$self->close; # queues end_obj->event_step to be called
	} # else { # we may've been requeued but closed by $http
}

# once this is called, all data we read is passed to the
# to the PublicInbox::HTTP instance ($http) via $fh->write
sub async_pass {
	my ($self, $http, $fh, $bref) = @_;
	# In case the client HTTP connection ($http) dies, it
	# will automatically close this ($self) object.
	$http->{forward} = $self;

	# write anything we overread when we were reading headers
	$fh->write($$bref); # PublicInbox:HTTP::{chunked,identity}_wcb

	# we're done with this, free this memory up ASAP since the
	# calls after this may use much memory:
	$$bref = undef;

	$self->{http} = $http;
	$self->{fh} = $fh;
}

# may be called as $forward->close in PublicInbox::HTTP or EOF (event_step)
sub close {
	my $self = $_[0];
	$self->SUPER::close; # DS::close

	# we defer this to the next timer loop since close is deferred
	if (my $end_obj = delete $self->{end_obj}) {
		# this calls $end_obj->event_step
		# (likely PublicInbox::Qspawn::event_step,
		#  NOT PublicInbox::HTTPD::Async::event_step)
		PublicInbox::DS::requeue($end_obj);
	}
}

1;
