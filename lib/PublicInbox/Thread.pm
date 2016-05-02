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
# WARNING! both these Mail::Thread knobs were found by inspecting
# the Mail::Thread 2.55 source code, and we have some monkey patches
# in PublicInbox::Thread to fix memory leaks.  Since Mail::Thread
# appears unmaintained, I suppose it's safe to depend on these
# variables for now:
{
	no warnings 'once';
	# we want strict threads to expose (and hopefully discourage)
	# use of broken email clients
	$Mail::Thread::nosubject = 1;
	# Keep ghosts with only a single direct child,
	# don't hide that there may be missing messages.
	$Mail::Thread::noprune = 1;
}

if ($Mail::Thread::VERSION <= 2.55) {
	eval q(sub _container_class { 'PublicInbox::Thread::Container' });
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
