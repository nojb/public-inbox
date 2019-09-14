# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# XXX This is a totally unstable API for public-inbox internal use only
# This is exposed via the 'pi-httpd.async' key in the PSGI env hash.
# The name of this key is not even stable!
# Currently intended for use with read-only pipes with expensive
# processes such as git-http-backend(1), cgit(1)
package PublicInbox::HTTPD::Async;
use strict;
use warnings;
use base qw(PublicInbox::DS);
use fields qw(cb end);
use Errno qw(EAGAIN);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);

# This is called via: $env->{'pi-httpd.async'}->()
# $io is a read-only pipe ($rpipe) for now, but may be a
# bidirectional socket in the future.
sub new {
	my ($class, $io, $cb, $end) = @_;

	# no $io? call $cb at the top of the next event loop to
	# avoid recursion:
	unless (defined($io)) {
		PublicInbox::DS::requeue($cb);
		die '$end unsupported w/o $io' if $end;
		return;
	}

	my $self = fields::new($class);
	IO::Handle::blocking($io, 0);
	$self->SUPER::new($io, EPOLLIN | EPOLLET);
	$self->{cb} = $cb; # initial read callback, later replaced by main_cb
	$self->{end} = $end; # like END {}, but only for this object
	$self;
}

sub main_cb ($$) {
	my ($http, $fh) = @_;
	sub {
		my ($self) = @_;
		# $self->{sock} is a read pipe for git-http-backend or cgit
		# and 65536 is the default Linux pipe size
		my $r = sysread($self->{sock}, my $buf, 65536);
		if ($r) {
			$fh->write($buf); # may call $http->close
			if ($http->{sock}) { # !closed
				$self->requeue;
				# let other clients get some work done, too
				return;
			}

			# else: fall through to close below...
		} elsif (!defined $r && $! == EAGAIN) {
			return; # EPOLLET means we'll be notified
		}

		# Done! Error handling will happen in $fh->close
		# called by the {end} handler
		delete $http->{forward};
		$self->close; # queues ->{end} to be called
	}
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

	# replace the header read callback with the main one
	my $cb = $self->{cb} = main_cb($http, $fh);
	$cb->($self); # either hit EAGAIN or ->requeue to keep EPOLLET happy
}

sub event_step {
	# {cb} may be undef after ->requeue due to $http->close happening
	my $cb = $_[0]->{cb} or return;
	$cb->(@_);
}

# may be called as $forward->close in PublicInbox::HTTP or EOF (main_cb)
sub close {
	my $self = $_[0];
	delete $self->{cb};
	$self->SUPER::close; # DS::close

	# we defer this to the next timer loop since close is deferred
	if (my $end = delete $self->{end}) {
		PublicInbox::DS::requeue($end);
	}
}

1;
