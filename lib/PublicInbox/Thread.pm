# subclass Mail::Thread and use this to workaround a memory leak
# Based on the patch in: https://rt.cpan.org/Public/Bug/Display.html?id=22817
#
# Additionally, workaround for a bug where $walk->topmost returns undef:
# - http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=795913
# - https://rt.cpan.org/Ticket/Display.html?id=106498
#
# License differs from the rest of public-inbox (but is compatible):
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
package PublicInbox::Thread;
use strict;
use warnings;
use base qw(Mail::Thread);

if ($Mail::Thread::VERSION <= 2.55) {
	eval q(sub _container_class { 'PublicInbox::Thread::Container' });
}

sub sort_ts {
	sort {
		(eval { $a->topmost->message->header('X-PI-TS') } || 0) <=>
		(eval { $b->topmost->message->header('X-PI-TS') } || 0)
	} @_;
}

sub rsort_ts {
	sort {
		(eval { $b->topmost->message->header('X-PI-TS') } || 0) <=>
		(eval { $a->topmost->message->header('X-PI-TS') } || 0)
	} @_;
}

package PublicInbox::Thread::Container;
use strict;
use warnings;
use base qw(Mail::Thread::Container);
use Scalar::Util qw(weaken);
sub parent { @_ == 2 ? weaken($_[0]->{parent} = $_[1]) : $_[0]->{parent} }

sub topmost {
	$_[0]->SUPER::topmost || PublicInbox::Thread::CPANRTBug106498->new;
}

# ref:
# - http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=795913
# - https://rt.cpan.org/Ticket/Display.html?id=106498
package PublicInbox::Thread::CPANRTBug106498;
use strict;
use warnings;

sub new { bless {}, $_[0] }

sub simple_subject {}

1;
