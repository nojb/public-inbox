# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# only for PublicInbox::Daemon, allows worker processes to be
# notified if the master process dies.
package PublicInbox::ParentPipe;
use strict;
use warnings;
use base qw(PublicInbox::DS);
use fields qw(cb);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);

sub new ($$$) {
	my ($class, $pipe, $worker_quit) = @_;
	my $self = fields::new($class);
	$self->SUPER::new($pipe, EPOLLIN|EPOLLONESHOT);
	$self->{cb} = $worker_quit;
	$self;
}

# master process died, time to call worker_quit ourselves
sub event_step {
	$_[0]->close; # PublicInbox::DS::close
	$_[0]->{cb}->();
}

1;
