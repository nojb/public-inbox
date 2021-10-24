# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Generic PSGI server for convenience.  It aims to provide
# a consistent experience for public-inbox admins so they don't have
# to learn different ways to admin both NNTP and HTTP components.
# There's nothing which depends on public-inbox, here.
# Each instance of this class represents a HTTP client socket
#
# fields:
# httpd: PublicInbox::HTTPD ref
# env: PSGI env hashref
# input_left: bytes left to read in request body (e.g. POST/PUT)
# remote_addr: remote IP address as a string (e.g. "127.0.0.1")
# remote_port: peer port
# forward: response body object, response to ->getline + ->close
# alive: HTTP keepalive state:
#	0: drop connection when done
#	1: keep connection when done
#	2: keep connection, chunk responses
package PublicInbox::HTTP;
use strict;
use parent qw(PublicInbox::DS);
use Fcntl qw(:seek);
use Plack::HTTPParser qw(parse_http_request); # XS or pure Perl
use Plack::Util;
use HTTP::Status qw(status_message);
use HTTP::Date qw(time2str);
use PublicInbox::DS qw(msg_more);
use PublicInbox::Syscall qw(EPOLLIN EPOLLONESHOT);
use PublicInbox::Tmpfile;
use constant {
	CHUNK_START => -1,   # [a-f0-9]+\r\n
	CHUNK_END => -2,     # \r\n
	CHUNK_ZEND => -3,    # \r\n
	CHUNK_MAX_HDR => 256,
};
use Errno qw(EAGAIN);

# Use the same configuration parameter as git since this is primarily
# a slow-client sponge for git-http-backend
# TODO: support per-respository http.maxRequestBuffer somehow...
our $MAX_REQUEST_BUFFER = $ENV{GIT_HTTP_MAX_REQUEST_BUFFER} ||
			(10 * 1024 * 1024);

open(my $null_io, '<', '/dev/null') or die "failed to open /dev/null: $!";
my $http_date;
my $prev = 0;
sub http_date () {
	my $now = time;
	$now == $prev ? $http_date : ($http_date = time2str($prev = $now));
}

sub new ($$$) {
	my ($class, $sock, $addr, $httpd) = @_;
	my $self = bless { httpd => $httpd }, $class;
	my $ev = EPOLLIN;
	my $wbuf;
	if ($sock->can('accept_SSL') && !$sock->accept_SSL) {
		return CORE::close($sock) if $! != EAGAIN;
		$ev = PublicInbox::TLS::epollbit() or return CORE::close($sock);
		$wbuf = [ \&PublicInbox::DS::accept_tls_step ];
	}
	$self->{wbuf} = $wbuf if $wbuf;
	($self->{remote_addr}, $self->{remote_port}) =
		PublicInbox::Daemon::host_with_port($addr);
	$self->SUPER::new($sock, $ev | EPOLLONESHOT);
}

sub event_step { # called by PublicInbox::DS
	my ($self) = @_;

	return unless $self->flush_write && $self->{sock};

	# only read more requests if we've drained the write buffer,
	# otherwise we can be buffering infinitely w/o backpressure

	return read_input($self) if ref($self->{env});

	my $rbuf = $self->{rbuf} // (\(my $x = ''));
	my %env = %{$self->{httpd}->{env}}; # full hash copy
	my $r;
	while (($r = parse_http_request($$rbuf, \%env)) < 0) {
		# We do not support Trailers in chunked requests, for
		# now (they are rarely-used and git (as of 2.7.2) does
		# not use them).
		# this length-check is necessary for PURE_PERL=1:
		if ($r == -1 || $env{HTTP_TRAILER} ||
				($r == -2 && length($$rbuf) > 0x4000)) {
			return quit($self, 400);
		}
		$self->do_read($rbuf, 8192, length($$rbuf)) or return;
	}
	return quit($self, 400) if grep(/\s/, keys %env); # stop smugglers
	$$rbuf = substr($$rbuf, $r);
	my $len = input_prepare($self, \%env) //
		return write_err($self, undef); # EMFILE/ENFILE

	$len ? read_input($self, $rbuf) : app_dispatch($self, undef, $rbuf);
}

sub read_input ($;$) {
	my ($self, $rbuf) = @_;
	$rbuf //= $self->{rbuf} // (\(my $x = ''));
	my $env = $self->{env};
	return read_input_chunked($self, $rbuf) if env_chunked($env);

	# env->{CONTENT_LENGTH} (identity)
	my $len = delete $self->{input_left};
	my $input = $env->{'psgi.input'};

	while ($len > 0) {
		if ($$rbuf ne '') {
			my $w = syswrite($input, $$rbuf, $len);
			return write_err($self, $len) unless $w;
			$len -= $w;
			die "BUG: $len < 0 (w=$w)" if $len < 0;
			if ($len == 0) { # next request may be pipelined
				$$rbuf = substr($$rbuf, $w);
				last;
			}
			$$rbuf = '';
		}
		$self->do_read($rbuf, 8192) or return recv_err($self, $len);
		# continue looping if $r > 0;
	}
	app_dispatch($self, $input, $rbuf);
}

sub app_dispatch {
	my ($self, $input, $rbuf) = @_;
	$self->rbuf_idle($rbuf);
	my $env = $self->{env};
	$self->{env} = undef; # for exists() check in ->busy
	$env->{REMOTE_ADDR} = $self->{remote_addr};
	$env->{REMOTE_PORT} = $self->{remote_port};
	if (defined(my $host = $env->{HTTP_HOST})) {
		$host =~ s/:([0-9]+)\z// and $env->{SERVER_PORT} = $1;
		$env->{SERVER_NAME} = $host;
	}
	if (defined $input) {
		sysseek($input, 0, SEEK_SET) or
			die "BUG: psgi.input seek failed: $!";
	}
	# note: NOT $self->{sock}, we want our close (+ PublicInbox::DS::close),
	# to do proper cleanup:
	$env->{'psgix.io'} = $self; # for ->close or async_pass
	my $res = Plack::Util::run_app($self->{httpd}->{app}, $env);
	eval {
		if (ref($res) eq 'CODE') {
			$res->(sub { response_write($self, $env, $_[0]) });
		} else {
			response_write($self, $env, $res);
		}
	};
	if ($@) {
		warn "response_write error: $@";
		$self->close;
	}
}

sub response_header_write {
	my ($self, $env, $res) = @_;
	my $proto = $env->{SERVER_PROTOCOL} or return; # HTTP/0.9 :P
	my $status = $res->[0];
	my $h = "$proto $status " . status_message($status) . "\r\n";
	my ($len, $chunked);
	my $headers = $res->[1];

	for (my $i = 0; $i < @$headers; $i += 2) {
		my $k = $headers->[$i];
		my $v = $headers->[$i + 1];
		next if $k =~ /\A(?:Connection|Date)\z/i;

		$len = $v if $k =~ /\AContent-Length\z/i;
		if ($k =~ /\ATransfer-Encoding\z/i && $v =~ /\bchunked\b/i) {
			$chunked = 1;
		}
		$h .= "$k: $v\r\n";
	}

	my $conn = $env->{HTTP_CONNECTION} || '';
	my $term = defined($len) || $chunked;
	my $prot_persist = ($proto eq 'HTTP/1.1') && ($conn !~ /\bclose\b/i);
	my $alive;
	if (!$term && $prot_persist) { # auto-chunk
		$chunked = $alive = 2;
		$h .= "Transfer-Encoding: chunked\r\n";
		# no need for "Connection: keep-alive" with HTTP/1.1
	} elsif ($term && ($prot_persist || ($conn =~ /\bkeep-alive\b/i))) {
		$alive = 1;
		$h .= "Connection: keep-alive\r\n";
	} else {
		$alive = 0;
		$h .= "Connection: close\r\n";
	}
	$h .= 'Date: ' . http_date() . "\r\n\r\n";

	if (($len || $chunked) && $env->{REQUEST_METHOD} ne 'HEAD') {
		msg_more($self, $h);
	} else {
		$self->write(\$h);
	}
	$alive;
}

# middlewares such as Deflater may write empty strings
sub chunked_write ($$) {
	my $self = $_[0];
	return if $_[1] eq '';
	msg_more($self, sprintf("%x\r\n", length($_[1])));
	msg_more($self, $_[1]);

	# use $self->write(\"\n\n") if you care about real-time
	# streaming responses, public-inbox WWW does not.
	msg_more($self, "\r\n");
}

sub identity_write ($$) {
	my $self = $_[0];
	$self->write(\($_[1])) if $_[1] ne '';
}

sub response_done {
	my ($self, $alive) = @_;
	delete $self->{env}; # we're no longer busy
	$self->write(\"0\r\n\r\n") if $alive == 2;
	$self->write($alive ? $self->can('requeue') : \&close);
}

sub getline_pull {
	my ($self) = @_;
	my $forward = $self->{forward};

	# limit our own running time for fairness with other
	# clients and to avoid buffering too much:
	my $buf = eval {
		local $/ = \65536;
		$forward->getline;
	} if $forward;

	if (defined $buf) {
		# may close in PublicInbox::DS::write
		if ($self->{alive} == 2) {
			chunked_write($self, $buf);
		} else {
			identity_write($self, $buf);
		}

		if ($self->{sock}) {
			# autovivify wbuf
			my $new_size = push(@{$self->{wbuf}}, \&getline_pull);

			# wbuf may be populated by {chunked,identity}_write()
			# above, no need to rearm if so:
			$self->requeue if $new_size == 1;
			return; # likely
		}
	} elsif ($@) {
		warn "response ->getline error: $@";
		$self->close;
	}
	# avoid recursion
	if (delete $self->{forward}) {
		eval { $forward->close };
		if ($@) {
			warn "response ->close error: $@";
			$self->close; # idempotent
		}
	}
	response_done($self, delete $self->{alive});
}

sub response_write {
	my ($self, $env, $res) = @_;
	my $alive = response_header_write($self, $env, $res);
	if (defined(my $body = $res->[2])) {
		if (ref $body eq 'ARRAY') {
			if ($alive == 2) {
				chunked_write($self, $_) for @$body;
			} else {
				identity_write($self, $_) for @$body;
			}
			response_done($self, $alive);
		} else {
			$self->{forward} = $body;
			$self->{alive} = $alive;
			getline_pull($self); # kick-off!
		}
	# these are returned to the calling application:
	} elsif ($alive == 2) {
		bless [ $self, $alive ], 'PublicInbox::HTTP::Chunked';
	} else {
		bless [ $self, $alive ], 'PublicInbox::HTTP::Identity';
	}
}

sub input_prepare {
	my ($self, $env) = @_;
	my ($input, $len);

	# rfc 7230 3.3.2, 3.3.3,: favor Transfer-Encoding over Content-Length
	my $hte = $env->{HTTP_TRANSFER_ENCODING};
	if (defined $hte) {
		# rfc7230 3.3.3, point 3 says only chunked is accepted
		# as the final encoding.  Since neither public-inbox-httpd,
		# git-http-backend, or our WWW-related code uses "gzip",
		# "deflate" or "compress" as the Transfer-Encoding, we'll
		# reject them:
		return quit($self, 400) if $hte !~ /\Achunked\z/i;

		$len = CHUNK_START;
		$input = tmpfile('http.input', $self->{sock});
	} else {
		$len = $env->{CONTENT_LENGTH};
		if (defined $len) {
			# rfc7230 3.3.3.4
			return quit($self, 400) if $len !~ /\A[0-9]+\z/;
			return quit($self, 413) if $len > $MAX_REQUEST_BUFFER;
			$input = $len ? tmpfile('http.input', $self->{sock})
				: $null_io;
		} else {
			$input = $null_io;
		}
	}

	# TODO: expire idle clients on ENFILE / EMFILE
	$env->{'psgi.input'} = $input // return;
	$self->{env} = $env;
	$self->{input_left} = $len || 0;
}

sub env_chunked { ($_[0]->{HTTP_TRANSFER_ENCODING} // '') =~ /\Achunked\z/i }

sub write_err {
	my ($self, $len) = @_;
	my $msg = $! || '(zero write)';
	$msg .= " ($len bytes remaining)" if defined $len;
	warn "error buffering to input: $msg";
	quit($self, 500);
}

sub recv_err {
	my ($self, $len) = @_;
	if ($! == EAGAIN) { # epoll/kevent watch already set by do_read
		$self->{input_left} = $len;
	} else {
		warn "error reading input: $! ($len bytes remaining)";
	}
}

sub read_input_chunked { # unlikely...
	my ($self, $rbuf) = @_;
	$rbuf //= $self->{rbuf} // (\(my $x = ''));
	my $input = $self->{env}->{'psgi.input'};
	my $len = delete $self->{input_left};

	while (1) { # chunk start
		if ($len == CHUNK_ZEND) {
			$$rbuf =~ s/\A\r\n//s and
				return app_dispatch($self, $input, $rbuf);

			return quit($self, 400) if length($$rbuf) > 2;
		}
		if ($len == CHUNK_END) {
			if ($$rbuf =~ s/\A\r\n//s) {
				$len = CHUNK_START;
			} elsif (length($$rbuf) > 2) {
				return quit($self, 400);
			}
		}
		if ($len == CHUNK_START) {
			if ($$rbuf =~ s/\A([a-f0-9]+).*?\r\n//i) {
				$len = hex $1;
				if (($len + -s $input) > $MAX_REQUEST_BUFFER) {
					return quit($self, 413);
				}
			} elsif (length($$rbuf) > CHUNK_MAX_HDR) {
				return quit($self, 400);
			}
			# will break from loop since $len >= 0
		}

		if ($len < 0) { # chunk header is trickled, read more
			$self->do_read($rbuf, 8192, length($$rbuf)) or
				return recv_err($self, $len);
			# (implicit) goto chunk_start if $r > 0;
		}
		$len = CHUNK_ZEND if $len == 0;

		# drain the current chunk
		until ($len <= 0) {
			if ($$rbuf ne '') {
				my $w = syswrite($input, $$rbuf, $len);
				return write_err($self, "$len chunk") if !$w;
				$len -= $w;
				if ($len == 0) {
					# we may have leftover data to parse
					# in chunk
					$$rbuf = substr($$rbuf, $w);
					$len = CHUNK_END;
				} elsif ($len < 0) {
					die "BUG: len < 0: $len";
				} else {
					$$rbuf = '';
				}
			}
			if ($$rbuf eq '') {
				# read more of current chunk
				$self->do_read($rbuf, 8192) or
					return recv_err($self, $len);
			}
		}
	}
}

sub quit {
	my ($self, $status) = @_;
	my $h = "HTTP/1.1 $status " . status_message($status) . "\r\n\r\n";
	$self->write(\$h);
	$self->close;
	undef; # input_prepare expects this
}

sub close {
	my $self = $_[0];
	if (my $forward = delete $self->{forward}) {
		eval { $forward->close };
		warn "forward ->close error: $@" if $@;
	}
	$self->SUPER::close; # PublicInbox::DS::close
}

sub busy { # for graceful shutdown in PublicInbox::Daemon:
	my ($self) = @_;
	defined($self->{rbuf}) || exists($self->{env}) || defined($self->{wbuf})
}

# runs $cb on the next iteration of the event loop at earliest
sub next_step {
	my ($self, $cb) = @_;
	return unless exists $self->{sock};
	$self->requeue if 1 == push(@{$self->{wbuf}}, $cb);
}

# Chunked and Identity packages are used for writing responses.
# They may be exposed to the PSGI application when the PSGI app
# returns a CODE ref for "push"-based responses
package PublicInbox::HTTP::Chunked;
use strict;

sub write {
	# ([$http], $buf) = @_;
	PublicInbox::HTTP::chunked_write($_[0]->[0], $_[1])
}

sub close {
	# $_[0] = [$http, $alive]
	PublicInbox::HTTP::response_done(@{$_[0]});
}

package PublicInbox::HTTP::Identity;
use strict;
our @ISA = qw(PublicInbox::HTTP::Chunked);

sub write {
	# ([$http], $buf) = @_;
	PublicInbox::HTTP::identity_write($_[0]->[0], $_[1]);
}

1;
