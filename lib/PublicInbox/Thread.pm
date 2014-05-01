# subclass Mail::Thread and use this to workaround a memory leak
# Based on the patch in: https://rt.cpan.org/Public/Bug/Display.html?id=22817
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

package PublicInbox::Thread::Container;
use strict;
use warnings;
use base qw(Mail::Thread::Container);
use Scalar::Util qw(weaken);
sub parent { @_ == 2 ? weaken($_[0]->{parent} = $_[1]) : $_[0]->{parent} }

1;
