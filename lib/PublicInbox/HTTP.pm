# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Generic PSGI server for convenience.  It aims to provide
# a consistent experience for public-inbox admins so they don't have
# to learn different ways to admin both NNTP and HTTP components.
# There's nothing public-inbox-specific, here.
# Each instance of this class represents a HTTP client socket

package PublicInbox::HTTP;
use strict;
use warnings;
use base qw(Danga::Socket);
use fields qw(httpd env rbuf input_left remote_addr remote_port);
use Fcntl qw(:seek);
use Plack::HTTPParser qw(parse_http_request); # XS or pure Perl
use HTTP::Status qw(status_message);
use HTTP::Date qw(time2str);
use IO::File;
use constant {
	CHUNK_START => -1,   # [a-f0-9]+\r\n
	CHUNK_END => -2,     # \r\n
	CHUNK_ZEND => -3,    # \r\n
	CHUNK_MAX_HDR => 256,
};

# FIXME: duplicated code with NNTP.pm
my $WEAKEN = {}; # string(inbox) -> inbox
my $WEAKTIMER;
sub weaken_task () {
	$WEAKTIMER = undef;
	$_->weaken_all for values %$WEAKEN;
	$WEAKEN = {};
}

# Use the same configuration parameter as git since this is primarily
# a slow-client sponge for git-http-backend
# TODO: support per-respository http.maxRequestBuffer somehow...
our $MAX_REQUEST_BUFFER = $ENV{GIT_HTTP_MAX_REQUEST_BUFFER} ||
			(10 * 1024 * 1024);

my $null_io = IO::File->new('/dev/null', '<');
my $http_date;
my $prev = 0;
sub http_date () {
	my $now = time;
	$now == $prev ? $http_date : ($http_date = time2str($prev = $now));
}

sub new ($$$) {
	my ($class, $sock, $addr, $httpd) = @_;
	my $self = fields::new($class);
	$self->SUPER::new($sock);
	$self->{httpd} = $httpd;
	$self->{rbuf} = '';
	($self->{remote_addr}, $self->{remote_port}) =
		PublicInbox::Daemon::host_with_port($addr);
	$self->watch_read(1);
	$self;
}

sub event_read { # called by Danga::Socket
	my ($self) = @_;

	return event_read_input($self) if defined $self->{env};

	my $off = length($self->{rbuf});
	my $r = sysread($self->{sock}, $self->{rbuf}, 8192, $off);
	if (defined $r) {
		return $self->close if $r == 0;
		return rbuf_process($self);
	}
	return if $!{EAGAIN}; # no need to call watch_read(1) again

	# common for clients to break connections without warning,
	# would be too noisy to log here:
	return $self->close;
}

sub rbuf_process {
	my ($self) = @_;

	my %env = %{$self->{httpd}->{env}}; # full hash copy
	my $r = parse_http_request($self->{rbuf}, \%env);

	# We do not support Trailers in chunked requests, for now
	# (they are rarely-used and git (as of 2.7.2) does not use them)
	if ($r == -1 || $env{HTTP_TRAILER} ||
			# this length-check is necessary for PURE_PERL=1:
			($r == -2 && length($self->{rbuf}) > 0x4000)) {
		return quit($self, 400);
	}
	return $self->watch_read(1) if $r < 0; # incomplete
	$self->{rbuf} = substr($self->{rbuf}, $r);

	my $len = input_prepare($self, \%env);
	defined $len or return write_err($self); # EMFILE/ENFILE

	$len ? event_read_input($self) : app_dispatch($self);
}

sub event_read_input ($) {
	my ($self) = @_;
	my $env = $self->{env};
	return event_read_input_chunked($self) if env_chunked($env);

	# env->{CONTENT_LENGTH} (identity)
	my $sock = $self->{sock};
	my $len = $self->{input_left};
	$self->{input_left} = undef;
	my $rbuf = \($self->{rbuf});
	my $input = $env->{'psgi.input'};

	while ($len > 0) {
		if ($$rbuf ne '') {
			my $w = write_in_full($input, $rbuf, $len);
			return write_err($self) unless $w;
			$len -= $w;
			die "BUG: $len < 0 (w=$w)" if $len < 0;
			if ($len == 0) { # next request may be pipelined
				$$rbuf = substr($$rbuf, $w);
				last;
			}
			$$rbuf = '';
		}
		my $r = sysread($sock, $$rbuf, 8192);
		return recv_err($self, $r, $len) unless $r;
		# continue looping if $r > 0;
	}
	app_dispatch($self, $input);
}

sub app_dispatch {
	my ($self, $input) = @_;
	$self->watch_read(0);
	my $env = $self->{env};
	$env->{REMOTE_ADDR} = $self->{remote_addr};
	$env->{REMOTE_PORT} = $self->{remote_port};
	if (my $host = $env->{HTTP_HOST}) {
		$host =~ s/:(\d+)\z// and $env->{SERVER_PORT} = $1;
		$env->{SERVER_NAME} = $host;
	}
	if (defined $input) {
		sysseek($input, 0, SEEK_SET) or
			die "BUG: psgi.input seek failed: $!";
	}
	# note: NOT $self->{sock}, we want our close (+ Danga::Socket::close),
	# to do proper cleanup:
	$env->{'psgix.io'} = $self; # only for ->close
	my $res = Plack::Util::run_app($self->{httpd}->{app}, $env);
	eval {
		if (ref($res) eq 'CODE') {
			$res->(sub { response_write($self, $env, $_[0]) });
		} else {
			response_write($self, $env, $res);
		}
	};
	$self->close if $@;
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
	my $alive = $term &&
			(($proto eq 'HTTP/1.1' && $conn !~ /\bclose\b/i) ||
			 ($conn =~ /\bkeep-alive\b/i));

	$h .= 'Connection: ' . ($alive ? 'keep-alive' : 'close');
	$h .= "\r\nDate: " . http_date() . "\r\n\r\n";

	if (($len || $chunked) && $env->{REQUEST_METHOD} ne 'HEAD') {
		more($self, $h);
	} else {
		$self->write($h);
	}
	$alive;
}

sub response_write {
	my ($self, $env, $res) = @_;
	my $alive = response_header_write($self, $env, $res);

	# middlewares such as Deflater may write empty strings
	my $write = sub { $self->write($_[0]) if $_[0] ne '' };
	my $close = sub {
		if ($alive) {
			$self->event_write; # watch for readability if done
		} else {
			Danga::Socket::write($self, sub { $self->close });
		}
		if (my $obj = $env->{'pi-httpd.inbox'}) {
			# grace period for reaping resources
			$WEAKEN->{"$obj"} = $obj;
			$WEAKTIMER ||= Danga::Socket->AddTimer(60, *weaken_task);
		}
		$self->{env} = undef;
	};

	if (defined(my $body = $res->[2])) {
		if (ref $body eq 'ARRAY') {
			$write->($_) foreach @$body;
			$close->();
		} elsif ($body->can('async_pass')) { # HTTPD::Async
			# prevent us from reading the body faster than we
			# can write to the client
			my $restart_read = sub { $body->watch_read(1) };
			$body->async_pass(sub {
				local $/ = \8192;
				my $buf = $body->getline;
				if (defined $buf) {
					$write->($buf);
					if ($self->{write_buf}) {
						$body->watch_read(0);
						$self->write($restart_read);
					}
					return; # continue waiting
				}
				$body->close;
				$close->();
			});
		} else {
			my $pull;
			$pull = sub {
				local $/ = \8192;
				while (defined(my $buf = $body->getline)) {
					$write->($buf);
					if ($self->{write_buf}) {
						$self->write($pull);
						return;
					}
				}
				$pull = undef;
				$body->close();
				$close->();
			};
			$pull->();
		}
	} else {
		# this is returned to the calling application:
		Plack::Util::inline_object(write => $write, close => $close);
	}
}

use constant MSG_MORE => ($^O eq 'linux') ? 0x8000 : 0;
sub more ($$) {
	my $self = $_[0];
	if (MSG_MORE && !$self->{write_buf_size}) {
		my $n = send($self->{sock}, $_[1], MSG_MORE);
		if (defined $n) {
			my $dlen = length($_[1]);
			return 1 if $n == $dlen; # all done!
			$_[1] = substr($_[1], $n, $dlen - $n);
			# fall through to normal write:
		}
	}
	$self->write($_[1]);
}

my $pipelineq = [];
my $next_tick;
sub process_pipelineq () {
	$next_tick = undef;
	my $q = $pipelineq;
	$pipelineq = [];
	rbuf_process($_) foreach @$q;
}

# overrides existing Danga::Socket method
sub event_write {
	my ($self) = @_;
	# only continue watching for readability when we are done writing:
	return if $self->write(undef) != 1;

	if ($self->{rbuf} eq '') { # wait for next request
		$self->watch_read(1);
	} else { # avoid recursion for pipelined requests
		push @$pipelineq, $self;
		$next_tick ||= Danga::Socket->AddTimer(0, *process_pipelineq);
	}
}

sub input_prepare {
	my ($self, $env) = @_;
	my $input = $null_io;
	my $len = $env->{CONTENT_LENGTH};
	if ($len) {
		if ($len > $MAX_REQUEST_BUFFER) {
			quit($self, 413);
			return;
		}
		$input = IO::File->new_tmpfile;
	} elsif (env_chunked($env)) {
		$len = CHUNK_START;
		$input = IO::File->new_tmpfile;
	}

	# TODO: expire idle clients on ENFILE / EMFILE
	return unless $input;

	$env->{'psgi.input'} = $input;
	$self->{env} = $env;
	$self->{input_left} = $len || 0;
}

sub env_chunked { ($_[0]->{HTTP_TRANSFER_ENCODING} || '') =~ /\bchunked\b/i }

sub write_err {
	my ($self) = @_;
	my $err = $self->{httpd}->{env}->{'psgi.errors'};
	my $msg = $! || '(zero write)';
	$err->print("error buffering to input: $msg\n");
	quit($self, 500);
}

sub recv_err {
	my ($self, $r, $len) = @_;
	return $self->close if (defined $r && $r == 0);
	if ($!{EAGAIN}) {
		$self->{input_left} = $len;
		return;
	}
	my $err = $self->{httpd}->{env}->{'psgi.errors'};
	$err->print("error reading for input: $! ($len bytes remaining)\n");
	quit($self, 500);
}

sub write_in_full {
	my ($fh, $rbuf, $len) = @_;
	my $rv = 0;
	my $off = 0;
	while ($len > 0) {
		my $w = syswrite($fh, $$rbuf, $len, $off);
		return ($rv ? $rv : $w) unless $w; # undef or 0
		$rv += $w;
		$off += $w;
		$len -= $w;
	}
	$rv
}

sub event_read_input_chunked { # unlikely...
	my ($self) = @_;
	my $input = $self->{env}->{'psgi.input'};
	my $sock = $self->{sock};
	my $len = $self->{input_left};
	$self->{input_left} = undef;
	my $rbuf = \($self->{rbuf});

	while (1) { # chunk start
		if ($len == CHUNK_ZEND) {
			$$rbuf =~ s/\A\r\n//s and
				return app_dispatch($self, $input);
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
			my $off = length($$rbuf);
			my $r = sysread($sock, $$rbuf, 8192, $off);
			return recv_err($self, $r, $len) unless $r;
			# (implicit) goto chunk_start if $r > 0;
		}
		$len = CHUNK_ZEND if $len == 0;

		# drain the current chunk
		until ($len <= 0) {
			if ($$rbuf ne '') {
				my $w = write_in_full($input, $rbuf, $len);
				return write_err($self) unless $w;
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
				my $r = sysread($sock, $$rbuf, 8192);
				return recv_err($self, $r, $len) unless $r;
			}
		}
	}
}

sub quit {
	my ($self, $status) = @_;
	my $h = "HTTP/1.1 $status " . status_message($status) . "\r\n\r\n";
	$self->write($h);
	$self->close;
}

# callbacks for Danga::Socket

sub event_hup { $_[0]->close }
sub event_err { $_[0]->close }

sub close {
	my $self = shift;
	$self->{env} = undef;
	$self->SUPER::close(@_);
}

# for graceful shutdown in PublicInbox::Daemon:
sub busy () {
	my ($self) = @_;
	($self->{rbuf} ne '' || $self->{env} || $self->{write_buf_size});
}

1;
