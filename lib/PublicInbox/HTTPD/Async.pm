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
use fields qw(cb);

sub new {
	my ($class, $io, $cb) = @_;
	my $self = fields::new($class);
	IO::Handle::blocking($io, 0);
	$self->SUPER::new($io);
	$self->{cb} = $cb;
	$self->watch_read(1);
	$self;
}

sub event_read { $_[0]->{cb}->() }
sub event_hup { $_[0]->{cb}->() }
sub event_err { $_[0]->{cb}->() }
sub sysread { shift->{sock}->sysread(@_) }

sub close {
	my $self = shift;
	$self->{cb} = undef;
	$self->SUPER::close(@_);
}

1;
