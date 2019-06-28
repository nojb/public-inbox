# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
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
use fields qw(cb cleanup);
use Errno qw(EAGAIN);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);

sub new {
	my ($class, $io, $cb, $cleanup) = @_;

	# no $io? call $cb at the top of the next event loop to
	# avoid recursion:
	unless (defined($io)) {
		PublicInbox::DS::requeue($cb);
		die 'cleanup unsupported w/o $io' if $cleanup;
		return;
	}

	my $self = fields::new($class);
	IO::Handle::blocking($io, 0);
	$self->SUPER::new($io, EPOLLIN | EPOLLET);
	$self->{cb} = $cb;
	$self->{cleanup} = $cleanup;
	$self;
}

sub main_cb ($$$) {
	my ($http, $fh, $bref) = @_;
	sub {
		my ($self) = @_;
		my $r = sysread($self->{sock}, $$bref, 8192);
		if ($r) {
			$fh->write($$bref); # may call $http->close
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
		# called by the {cleanup} handler
		delete $http->{forward};
		$self->close;
	}
}

sub async_pass {
	my ($self, $http, $fh, $bref) = @_;
	# In case the client HTTP connection ($http) dies, it
	# will automatically close this ($self) object.
	$http->{forward} = $self;
	$fh->write($$bref); # PublicInbox:HTTP::{chunked,identity}_wcb
	my $cb = $self->{cb} = main_cb($http, $fh, $bref);
	$cb->($self); # either hit EAGAIN or ->requeue to keep EPOLLET happy
}

sub event_step {
	# {cb} may be undef after ->requeue due to $http->close happening
	my $cb = $_[0]->{cb} or return;
	$cb->(@_);
}

sub close {
	my $self = $_[0];
	delete $self->{cb};
	$self->SUPER::close;

	# we defer this to the next timer loop since close is deferred
	if (my $cleanup = delete $self->{cleanup}) {
		PublicInbox::DS::requeue($cleanup);
	}
}

1;
