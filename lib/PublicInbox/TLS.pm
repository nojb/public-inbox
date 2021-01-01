# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# IO::Socket::SSL support code
package PublicInbox::TLS;
use strict;
use IO::Socket::SSL;
use PublicInbox::Syscall qw(EPOLLIN EPOLLOUT);
use Carp qw(carp);

sub err () { $SSL_ERROR }

# returns the EPOLL event bit which matches the existing SSL error
sub epollbit () {
	return EPOLLIN if $SSL_ERROR == SSL_WANT_READ;
	return EPOLLOUT if $SSL_ERROR == SSL_WANT_WRITE;
	carp "unexpected SSL error: $SSL_ERROR";
	undef;
}

1;
