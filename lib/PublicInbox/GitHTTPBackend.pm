# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# when no endpoints match, fallback to this and serve a static file
# or smart HTTP
package PublicInbox::GitHTTPBackend;
use strict;
use warnings;
use Fcntl qw(:seek);
use IO::File;
use PublicInbox::Spawn qw(spawn);
use HTTP::Date qw(time2str);

# TODO: make configurable, but keep in mind it's better to have
# multiple -httpd worker processes which are already scaled to
# the proper number of CPUs and memory.  git-pack-objects(1) may
# also use threads and bust memory limits, too, so I recommend
# limiting threads to 1 (via `pack.threads` knob in git) for serving.
my $LIMIT = 1;
my $nr_running = 0;

# n.b. serving "description" and "cloneurl" should be innocuous enough to
# not cause problems.  serving "config" might...
my @text = qw[HEAD info/refs
	objects/info/(?:http-alternates|alternates|packs)
	cloneurl description];

my @binary = qw!
	objects/[a-f0-9]{2}/[a-f0-9]{38}
	objects/pack/pack-[a-f0-9]{40}\.(?:pack|idx)
	!;

our $ANY = join('|', @binary, @text);
my $BIN = join('|', @binary);
my $TEXT = join('|', @text);

my @no_cache = ('Expires', 'Fri, 01 Jan 1980 00:00:00 GMT',
		'Pragma', 'no-cache',
		'Cache-Control', 'no-cache, max-age=0, must-revalidate');

my $nextq;
sub do_next () {
	my $q = $nextq;
	$nextq = undef;
	while (my $cb = shift @$q) {
		$cb->(); # this may redefine nextq
	}
}

sub r ($) {
	my ($s) = @_;
	[ $s, [qw(Content-Type text/plain Content-Length 0), @no_cache ], [] ]
}

sub serve {
	my ($cgi, $git, $path) = @_;
	return serve_dumb($cgi, $git, $path) if $nr_running >= $LIMIT;

	my $service = $cgi->param('service') || '';
	if ($service =~ /\Agit-\w+-pack\z/ || $path =~ /\Agit-\w+-pack\z/) {
		my $ok = serve_smart($cgi, $git, $path);
		return $ok if $ok;
	}

	serve_dumb($cgi, $git, $path);
}

sub err ($@) {
	my ($env, @msg) = @_;
	$env->{'psgi.errors'}->print(@msg, "\n");
}

sub drop_client ($) {
	if (my $io = $_[0]->{'psgix.io'}) {
		$io->close; # this is Danga::Socket::close
	}
}

sub serve_dumb {
	my ($cgi, $git, $path) = @_;

	my @h;
	my $type;
	if ($path =~ /\A(?:$BIN)\z/o) {
		$type = 'application/octet-stream';
		push @h, 'Expires', time2str(time + 31536000);
		push @h, 'Cache-Control', 'public, max-age=31536000';
	} elsif ($path =~ /\A(?:$TEXT)\z/o) {
		$type = 'text/plain';
		push @h, @no_cache;
	} else {
		return r(404);
	}

	my $f = "$git->{git_dir}/$path";
	return r(404) unless -f $f && -r _; # just in case it's a FIFO :P
	my @st = stat(_);
	my $size = $st[7];
	my $env = $cgi->{env};

	# TODO: If-Modified-Since and Last-Modified?
	open my $in, '<', $f or return r(404);
	my $len = $size;
	my $n = 65536; # try to negotiate a big TCP window, first
	my ($next, $fh);
	my $cb = sub {
		$n = $len if $len < $n;
		my $r = sysread($in, my $buf, $n);
		if (!defined $r) {
			err($env, "$f read error: $!");
			drop_client($env);
		} elsif ($r <= 0) {
			err($env, "$f EOF with $len bytes left");
			drop_client($env);
		} else {
			$len -= $r;
			$fh->write($buf);
			if ($len == 0) {
				$fh->close;
			} elsif ($next) {
				# avoid recursion in Danga::Socket::write
				unless ($nextq) {
					$nextq = [];
					Danga::Socket->AddTimer(0, *do_next);
				}
				# avoid buffering too much in case we have
				# slow clients:
				$n = 8192;
				push @$nextq, $next;
				return;
			}
		}
		# all done, cleanup references:
		$fh = $next = undef;
	};

	my $code = 200;
	push @h, 'Content-Type', $type;
	my $range = $env->{HTTP_RANGE};
	if (defined $range && $range =~ /\bbytes=(\d*)-(\d*)\z/) {
		($code, $len) = prepare_range($cgi, $in, \@h, $1, $2, $size);
		if ($code == 416) {
			push @h, 'Content-Range', "bytes */$size";
			return [ 416, \@h, [] ];
		}
	}
	push @h, 'Content-Length', $len;

	sub {
		my ($res) = @_; # Plack callback
		$fh = $res->([ $code, \@h ]);
		if (defined $env->{'pi-httpd.async'}) {
			my $pi_http = $env->{'psgix.io'};
			$next = sub { $pi_http->write($cb) };
			$cb->(); # start it off!
		} else {
			$cb->() while $fh;
		}
	}
}

sub prepare_range {
	my ($cgi, $in, $h, $beg, $end, $size) = @_;
	my $code = 200;
	my $len = $size;
	if ($beg eq '') {
		if ($end ne '') { # "bytes=-$end" => last N bytes
			$beg = $size - $end;
			$beg = 0 if $beg < 0;
			$end = $size - 1;
			$code = 206;
		} else {
			$code = 416;
		}
	} else {
		if ($beg > $size) {
			$code = 416;
		} elsif ($end eq '' || $end >= $size) {
			$end = $size - 1;
			$code = 206;
		} elsif ($end < $size) {
			$code = 206;
		} else {
			$code = 416;
		}
	}
	if ($code == 206) {
		$len = $end - $beg + 1;
		if ($len <= 0) {
			$code = 416;
		} else {
			sysseek($in, $beg, SEEK_SET) or return [ 500, [], [] ];
			push @$h, qw(Accept-Ranges bytes Content-Range);
			push @$h, "bytes $beg-$end/$size";

			# FIXME: Plack::Middleware::Deflater bug?
			$cgi->{env}->{'psgix.no-compress'} = 1;
		}
	}
	($code, $len);
}

# returns undef if 403 so it falls back to dumb HTTP
sub serve_smart {
	my ($cgi, $git, $path) = @_;
	my $env = $cgi->{env};

	my $input = $env->{'psgi.input'};
	my $buf;
	my $in;
	my $fd = eval { fileno($input) };
	if (defined $fd && $fd >= 0) {
		$in = $input;
	} else {
		$in = input_to_file($env) or return r(500);
	}
	my ($rpipe, $wpipe);
	unless (pipe($rpipe, $wpipe)) {
		err($env, "error creating pipe: $! - going static");
		return;
	}
	my %env = %ENV;
	# GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL
	# may be set in the server-process and are passed as-is
	foreach my $name (qw(QUERY_STRING
				REMOTE_USER REMOTE_ADDR
				HTTP_CONTENT_ENCODING
				CONTENT_TYPE
				SERVER_PROTOCOL
				REQUEST_METHOD)) {
		my $val = $env->{$name};
		$env{$name} = $val if defined $val;
	}
	my $git_dir = $git->{git_dir};
	$env{GIT_HTTP_EXPORT_ALL} = '1';
	$env{PATH_TRANSLATED} = "$git_dir/$path";
	my %rdr = ( 0 => fileno($in), 1 => fileno($wpipe) );
	my $pid = spawn([qw(git http-backend)], \%env, \%rdr);
	unless (defined $pid) {
		err($env, "error spawning: $! - going static");
		return;
	}
	$wpipe = $in = undef;
	$buf = '';
	my ($vin, $fh, $res);
	$nr_running++;

	# Danga::Socket users, we queue up the read_enable callback to
	# fire after pending writes are complete:
	my $pi_http = $env->{'psgix.io'};
	my $read_enable = sub { $rpipe->watch_read(1) };
	my $read_disable = sub {
		$rpipe->watch_read(0);
		$pi_http->write($read_enable);
	};

	my $end = sub {
		if ($fh) {
			$fh->close;
			$fh = undef;
		}
		if ($rpipe) {
			# _may_ be Danga::Socket::close via
			# PublicInbox::HTTPD::Async::close:
			$rpipe->close;
			$rpipe = undef;
			$nr_running--;
		}
		if (defined $pid) {
			my $e = $pid == waitpid($pid, 0) ?
				$? : "PID:$pid still running?";
			err($env, "git http-backend ($git_dir): $e") if $e;
		}
		return unless $res;
		my $dumb = serve_dumb($cgi, $git, $path);
		ref($dumb) eq 'ARRAY' ? $res->($dumb) : $dumb->($res);
	};
	my $fail = sub {
		if ($!{EAGAIN} || $!{EINTR}) {
			select($vin, undef, undef, undef) if defined $vin;
			# $vin is undef on async, so this is a noop on EAGAIN
			return;
		}
		my $e = $!;
		$end->();
		err($env, "git http-backend ($git_dir): $e\n");
	};
	my $cb = sub { # read git-http-backend output and stream to client
		my $r = $rpipe ? $rpipe->sysread($buf, 8192, length($buf)) : 0;
		return $fail->() unless defined $r;
		return $end->() if $r == 0; # EOF
		if ($fh) { # stream body from git-http-backend to HTTP client
			$fh->write($buf);
			$buf = '';
			$read_disable->() if $read_disable;
		} elsif ($buf =~ s/\A(.*?)\r\n\r\n//s) { # parse headers
			my $h = $1;
			my $code = 200;
			my @h;
			foreach my $l (split(/\r\n/, $h)) {
				my ($k, $v) = split(/:\s*/, $l, 2);
				if ($k =~ /\AStatus\z/i) {
					($code) = ($v =~ /\b(\d+)\b/);
				} else {
					push @h, $k, $v;
				}
			}
			if ($code == 403) {
				# smart cloning disabled, serve dumbly
				# in $end since we never undef $res in here
			} else { # write response header:
				$fh = $res->([ $code, \@h ]);
				$res = undef;
				$fh->write($buf);
			}
			$buf = '';
		} # else { keep reading ... }
	};
	if (my $async = $env->{'pi-httpd.async'}) {
		# $async is PublicInbox::HTTPD::Async->new($rpipe, $cb)
		$rpipe = $async->($rpipe, $cb);
		sub { ($res) = @_ } # let Danga::Socket handle the rest.
	} else { # synchronous loop for other PSGI servers
		$read_enable = $read_disable = undef;
		$vin = '';
		vec($vin, fileno($rpipe), 1) = 1;
		sub {
			($res) = @_;
			while ($rpipe) { $cb->() }
		}
	}
}

sub input_to_file {
	my ($env) = @_;
	my $in = IO::File->new_tmpfile;
	my $input = $env->{'psgi.input'};
	my $buf;
	while (1) {
		my $r = $input->read($buf, 8192);
		unless (defined $r) {
			err($env, "error reading input: $!");
			return;
		}
		last if ($r == 0);
		$in->write($buf);
	}
	$in->flush;
	$in->sysseek(0, SEEK_SET);
	return $in;
}

1;
