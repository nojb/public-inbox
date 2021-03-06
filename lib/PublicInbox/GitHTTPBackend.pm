# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# when no endpoints match, fallback to this and serve a static file
# or smart HTTP
package PublicInbox::GitHTTPBackend;
use strict;
use warnings;
use Fcntl qw(:seek);
use IO::Handle;
use HTTP::Date qw(time2str);
use HTTP::Status qw(status_message);
use Plack::Util;
use PublicInbox::Qspawn;

# 32 is same as the git-daemon connection limit
my $default_limiter = PublicInbox::Qspawn::Limiter->new(32);

# n.b. serving "description" and "cloneurl" should be innocuous enough to
# not cause problems.  serving "config" might...
my @text = qw[HEAD info/refs
	objects/info/(?:http-alternates|alternates|packs)
	cloneurl description];

my @binary = qw!
	objects/[a-f0-9]{2}/[a-f0-9]{38}
	objects/pack/pack-[a-f0-9]{40}\.(?:pack|idx)
	!;

our $ANY = join('|', @binary, @text, 'git-upload-pack');
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
	my ($env, $git, $path) = @_;

	# XXX compatibility... ugh, can we stop supporting this?
	$git = PublicInbox::Git->new($git) unless ref($git);

	# Documentation/technical/http-protocol.txt in git.git
	# requires one and exactly one query parameter:
	if ($env->{QUERY_STRING} =~ /\Aservice=git-\w+-pack\z/ ||
				$path =~ /\Agit-\w+-pack\z/) {
		my $ok = serve_smart($env, $git, $path);
		return $ok if $ok;
	}

	serve_dumb($env, $git, $path);
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

my $prev = 0;
my $exp;
sub cache_one_year {
	my ($h) = @_;
	my $t = time + 31536000;
	push @$h, 'Expires', $t == $prev ? $exp : ($exp = time2str($prev = $t)),
		'Cache-Control', 'public, max-age=31536000';
}

sub serve_dumb {
	my ($env, $git, $path) = @_;

	my @h;
	my $type;
	if ($path =~ m!\Aobjects/[a-f0-9]{2}/[a-f0-9]{38}\z!) {
		$type = 'application/x-git-loose-object';
		cache_one_year(\@h);
	} elsif ($path =~ m!\Aobjects/pack/pack-[a-f0-9]{40}\.pack\z!) {
		$type = 'application/x-git-packed-objects';
		cache_one_year(\@h);
	} elsif ($path =~ m!\Aobjects/pack/pack-[a-f0-9]{40}\.idx\z!) {
		$type = 'application/x-git-packed-objects-toc';
		cache_one_year(\@h);
	} elsif ($path =~ /\A(?:$TEXT)\z/o) {
		$type = 'text/plain';
		push @h, @no_cache;
	} else {
		return r(404);
	}

	my $f = $git->{git_dir} . '/' . $path;
	return r(404) unless -f $f && -r _; # just in case it's a FIFO :P
	my $size = -s _;

	# TODO: If-Modified-Since and Last-Modified?
	open my $in, '<', $f or return r(404);
	my $len = $size;
	my $code = 200;
	push @h, 'Content-Type', $type;
	if (($env->{HTTP_RANGE} || '') =~ /\bbytes=(\d*)-(\d*)\z/) {
		($code, $len) = prepare_range($env, $in, \@h, $1, $2, $size);
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
	my ($env, $in, $h, $beg, $end, $size) = @_;
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
			$env->{'psgix.no-compress'} = 1;
		}
	}
	($code, $len);
}

# returns undef if 403 so it falls back to dumb HTTP
sub serve_smart {
	my ($env, $git, $path) = @_;
	my $in = $env->{'psgi.input'};
	my $fd = eval { fileno($in) };
	unless (defined $fd && $fd >= 0) {
		$in = input_to_file($env) or return r(500);
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
	my $limiter = $git->{-httpbackend_limiter} || $default_limiter;
	my $git_dir = $git->{git_dir};
	$env{GIT_HTTP_EXPORT_ALL} = '1';
	$env{PATH_TRANSLATED} = "$git_dir/$path";
	my $rdr = { 0 => fileno($in) };
	my $qsp = PublicInbox::Qspawn->new([qw(git http-backend)], \%env, $rdr);
	my ($fh, $rpipe);
	my $end = sub {
		if (my $err = $qsp->finish) {
			err($env, "git http-backend ($git_dir): $err");
		}
		$fh->close if $fh; # async-only
	};

	# Danga::Socket users, we queue up the read_enable callback to
	# fire after pending writes are complete:
	my $buf = '';
	my $rd_hdr = sub {
		my $r = sysread($rpipe, $buf, 1024, length($buf));
		return if !defined($r) && ($!{EINTR} || $!{EAGAIN});
		return r(500, 'http-backend error') unless $r;
		$r = parse_cgi_headers(\$buf) or return; # incomplete headers
		$r->[0] == 403 ? serve_dumb($env, $git, $path) : $r;
	};
	my $res;
	my $async = $env->{'pi-httpd.async'}; # XXX unstable API
	my $cb = sub {
		my $r = $rd_hdr->() or return;
		$rd_hdr = undef;
		if (scalar(@$r) == 3) { # error:
			if ($async) {
				$async->close; # calls rpipe->close
			} else {
				$rpipe->close;
				$end->();
			}
			$res->($r);
		} elsif ($async) {
			$fh = $res->($r);
			$async->async_pass($env->{'psgix.io'}, $fh, \$buf);
		} else { # for synchronous PSGI servers
			require PublicInbox::GetlineBody;
			$r->[2] = PublicInbox::GetlineBody->new($rpipe, $end,
								$buf);
			$res->($r);
		}
	};
	sub {
		($res) = @_;

		# hopefully this doesn't break any middlewares,
		# holding the input here is a waste of FDs and memory
		$env->{'psgi.input'} = undef;

		$qsp->start($limiter, sub { # may run later, much later...
			($rpipe) = @_;
			$in = undef;
			if ($async) {
				$async = $async->($rpipe, $cb, $end);
			} else { # generic PSGI
				$cb->() while $rd_hdr;
			}
		});
	};
}

sub input_to_file {
	my ($env) = @_;
	open(my $in, '+>', undef);
	unless (defined $in) {
		err($env, "could not open temporary file: $!");
		return;
	}
	my $input = $env->{'psgi.input'};
	my $buf;
	while (1) {
		my $r = $input->read($buf, 8192);
		unless (defined $r) {
			err($env, "error reading input: $!");
			return;
		}
		my $off = 0;
		while ($r > 0) {
			my $w = syswrite($in, $buf, $r, $off);
			if (defined $w) {
				$r -= $w;
				$off += $w;
			} else {
				err($env, "error writing temporary file: $!");
				return;
			}
		}
	}
	unless (defined(sysseek($in, 0, SEEK_SET))) {
		err($env, "error seeking temporary file: $!");
		return;
	}
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
