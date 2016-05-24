# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# XXX This is a totally unstable API for public-inbox internal use only
# This is exposed via the 'pi-httpd.async' key in the PSGI env hash.
# The name of this key is not even stable!
# Currently is is intended for use with read-only pipes.
package PublicInbox::HTTPD::Async;
use strict;
use warnings;
use base qw(Danga::Socket);
use fields qw(cb cleanup);
require PublicInbox::EvCleanup;

sub new {
	my ($class, $io, $cb, $cleanup) = @_;
	my $self = fields::new($class);
	IO::Handle::blocking($io, 0);
	$self->SUPER::new($io);
	$self->{cb} = $cb;
	$self->{cleanup} = $cleanup;
	$self->watch_read(1);
	$self;
}

sub async_pass {
	my ($self, $io, $fh, $bref) = @_;
	my $restart_read = sub { $self->watch_read(1) };
	# In case the client HTTP connection ($io) dies, it
	# will automatically close this ($self) object.
	$io->{forward} = $self;
	$fh->write($$bref);
	$self->{cb} = sub {
		my $r = sysread($self->{sock}, $$bref, 8192);
		if ($r) {
			$fh->write($$bref);
			if ($io->{write_buf_size}) {
				$self->watch_read(0);
				$io->write($restart_read); # D::S::write
			}
			return; # stay in watch_read
		} elsif (!defined $r) {
			return if $!{EAGAIN} || $!{EINTR};
		}

		# Done! Error handling will happen in $fh->close
		# called by the {cleanup} handler
		$io->{forward} = undef;
		$self->close;
	}
}

sub event_read { $_[0]->{cb}->() }
sub event_hup { $_[0]->{cb}->() }
sub event_err { $_[0]->{cb}->() }
sub sysread { shift->{sock}->sysread(@_) }

sub close {
	my $self = shift;
	my $cleanup = $self->{cleanup};
	$self->{cleanup} = $self->{cb} = undef;
	$self->SUPER::close(@_);

	# we defer this to the next timer loop since close is deferred
	PublicInbox::EvCleanup::asap($cleanup) if $cleanup;
}

# do not let ourselves be closed during graceful termination
sub busy () { $_[0]->{cb} }

1;
