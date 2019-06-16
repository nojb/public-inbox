# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# only for PublicInbox::Daemon
package PublicInbox::ParentPipe;
use strict;
use warnings;
use base qw(PublicInbox::DS);
use fields qw(cb);

sub new ($$$) {
	my ($class, $pipe, $cb) = @_;
	my $self = fields::new($class);
	$self->SUPER::new($pipe);
	$self->{cb} = $cb;
	$self->watch_read(1);
	$self;
}

sub event_step { $_[0]->{cb}->($_[0]) }

1;
