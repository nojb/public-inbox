# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# IO::Socket::SSL support code
package PublicInbox::TLS;
use strict;
use IO::Socket::SSL;
use PublicInbox::Syscall qw(EPOLLIN EPOLLOUT);
use Carp qw(carp croak);

sub err () { $SSL_ERROR }

# returns the EPOLL event bit which matches the existing SSL error
sub epollbit () {
	return EPOLLIN if $SSL_ERROR == SSL_WANT_READ;
	return EPOLLOUT if $SSL_ERROR == SSL_WANT_WRITE;
	carp "unexpected SSL error: $SSL_ERROR";
	undef;
}

sub _ctx_new ($) {
	my ($tlsd) = @_;
	my $ctx = IO::Socket::SSL::SSL_Context->new(
				@{$tlsd->{ssl_ctx_opt}}, SSL_server => 1) or
		croak "SSL_Context->new: $SSL_ERROR";

	# save ~34K per idle connection (cf. SSL_CTX_set_mode(3ssl))
	# RSS goes from 346MB to 171MB with 10K idle NNTPS clients on amd64
	# cf. https://rt.cpan.org/Ticket/Display.html?id=129463
	my $mode = eval { Net::SSLeay::MODE_RELEASE_BUFFERS() };
	if ($mode && $ctx->{context}) {
		eval { Net::SSLeay::CTX_set_mode($ctx->{context}, $mode) };
		warn "W: $@ (setting SSL_MODE_RELEASE_BUFFERS)\n" if $@;
	}
	$ctx;
}

sub start {
	my ($io, $tlsd) = @_;
	IO::Socket::SSL->start_SSL($io, SSL_server => 1,
		SSL_reuse_ctx => ($tlsd->{ssl_ctx} //= _ctx_new($tlsd)),
		SSL_startHandshake => 0);
}

1;
