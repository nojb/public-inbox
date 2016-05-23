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
use HTTP::Status qw(status_message);

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

sub r ($;$) {
	my ($code, $msg) = @_;
	$msg ||= status_message($code);
	my $len = length($msg);
	[ $code, [qw(Content-Type text/plain Content-Length), $len, @no_cache],
		[$msg] ]
}

sub serve {
	my ($cgi, $git, $path) = @_;

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
	my $code = 200;
	push @h, 'Content-Type', $type;
	if (($env->{HTTP_RANGE} || '') =~ /\bbytes=(\d*)-(\d*)\z/) {
		($code, $len) = prepare_range($cgi, $in, \@h, $1, $2, $size);
		if ($code == 416) {
			push @h, 'Content-Range', "bytes */$size";
			return [ 416, \@h, [] ];
		}
	}
	push @h, 'Content-Length', $len;
	my $n = 65536;
	[ $code, \@h, Plack::Util::inline_object(close => sub { close $in },
		getline => sub {
			return if $len == 0;
			$n = $len if $len < $n;
			my $r = sysread($in, my $buf, $n);
			if (!defined $r) {
				err($env, "$f read error: $!");
			} elsif ($r <= 0) {
				err($env, "$f EOF with $len bytes left");
			} else {
				$len -= $r;
				$n = 8192;
				return $buf;
			}
			drop_client($env);
			return;
		})]
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
	my $in = $env->{'psgi.input'};
	my $fd = eval { fileno($in) };
	unless (defined $fd && $fd >= 0) {
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
	my $end = sub {
		$rpipe = undef;
		my $e = $pid == waitpid($pid, 0) ?
			$? : "PID:$pid still running?";
		if ($e) {
			err($env, "git http-backend ($git_dir): $e");
			drop_client($env);
		}
	};

	# Danga::Socket users, we queue up the read_enable callback to
	# fire after pending writes are complete:
	my $buf = '';
	if (my $async = $env->{'pi-httpd.async'}) {
		my $res;
		my $q = sub {
			$async->close;
			$end->();
			$res->(@_);
		};
		# $async is PublicInbox::HTTPD::Async->new($rpipe, $cb)
		$async = $async->($rpipe, sub {
			my $r = sysread($rpipe, $buf, 1024, length($buf));
			if (!defined $r || $r == 0) {
				return $q->(r(500, 'http-backend error'));
			}
			$r = parse_cgi_headers(\$buf) or return;
			if ($r->[0] == 403) {
				return $q->(serve_dumb($cgi, $git, $path));
			}
			my $fh = $res->($r);
			$fh->write($buf);
			$buf = undef;
			my $dst = Plack::Util::inline_object(
				write => sub { $fh->write(@_) },
				close => sub {
					$end->();
					$fh->close;
				});
			$async->async_pass($env->{'psgix.io'}, $dst);
		});
		sub { ($res) = @_ }; # let Danga::Socket handle the rest.
	} else { # getline + close for other PSGI servers
		my $r;
		do {
			$r = read($rpipe, $buf, 1024, length($buf));
			if (!defined $r || $r == 0) {
				return r(500, 'http-backend error');
			}
			$r = parse_cgi_headers(\$buf);
		} until ($r);
		return serve_dumb($cgi, $git, $path) if $r->[0] == 403;
		$r->[2] = Plack::Util::inline_object(
			close => sub { $end->() },
			getline => sub {
				my $ret = $buf;
				$buf = undef;
				defined $ret ? $ret : $rpipe->getline;
			});
		$r;

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

sub parse_cgi_headers {
	my ($bref) = @_;
	$$bref =~ s/\A(.*?)\r\n\r\n//s or return;
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
	[ $code, \@h ]
}

1;
