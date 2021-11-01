# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This package can either be a PSGI response body for a static file
# OR a standalone PSGI app which returns the above PSGI response body
# (or an HTML directory listing).
#
# It encapsulates the "autoindex", "index", and "gzip_static"
# functionality of nginx.
package PublicInbox::WwwStatic;
use strict;
use v5.10.1;
use parent qw(Exporter);
use Fcntl qw(SEEK_SET O_RDONLY O_NONBLOCK);
use POSIX qw(strftime);
use HTTP::Date qw(time2str);
use HTTP::Status qw(status_message);
use Errno qw(EACCES ENOTDIR ENOENT);
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::GzipFilter qw(gzf_maybe);
use PublicInbox::Hval qw(ascii_html);
use Plack::MIME;
our @EXPORT_OK = qw(@NO_CACHE r path_info_raw);

our @NO_CACHE = ('Expires', 'Fri, 01 Jan 1980 00:00:00 GMT',
		'Pragma', 'no-cache',
		'Cache-Control', 'no-cache, max-age=0, must-revalidate');

our $STYLE = <<'EOF';
<style>
@media screen {
	*{background:#000;color:#ccc}
	a{color:#69f;text-decoration:none}
	a:visited{color:#96f}
}
@media screen AND (prefers-color-scheme:light) {
	*{background:#fff;color:#333}
	a{color:#00f;text-decoration:none}
	a:visited{color:#808}
}
</style>
EOF

$STYLE =~ s/^\s*//gm;
$STYLE =~ tr/\n//d;

sub r ($;$) {
	my ($code, $msg) = @_;
	$msg ||= status_message($code);
	[ $code, [ qw(Content-Type text/plain), 'Content-Length', length($msg),
		@NO_CACHE ],
	  [ $msg ] ]
}

sub getline_response ($$$$$) {
	my ($env, $in, $off, $len, $path) = @_;
	my $r = bless {}, __PACKAGE__;
	if ($env->{'pi-httpd.async'}) { # public-inbox-httpd-only mode
		$env->{'psgix.no-compress'} = 1; # do not chunk response
		%$r = ( bypass => [$in, $off, $len, $env->{'psgix.io'}] );
	} else {
		%$r = ( in => $in, off => $off, len => $len, path => $path );
	}
	$r;
}

sub setup_range {
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
			push @$h, qw(Accept-Ranges bytes Content-Range);
			push @$h, "bytes $beg-$end/$size";

			# FIXME: Plack::Middleware::Deflater bug?
			$env->{'psgix.no-compress'} = 1;
		}
	}
	if ($code == 416) {
		push @$h, 'Content-Range', "bytes */$size";
		return [ 416, $h, [] ];
	}
	($code, $beg, $len);
}

# returns a PSGI arrayref response iff .gz and non-.gz mtimes match
sub try_gzip_static ($$$$) {
	my ($env, $h, $path, $type) = @_;
	return unless ($env->{HTTP_ACCEPT_ENCODING} // '') =~ /\bgzip\b/i;
	my $mtime;
	return unless -f $path && defined(($mtime = (stat(_))[9]));
	my $gz = "$path.gz";
	return unless -f $gz && (stat(_))[9] == $mtime;
	my $res = response($env, $h, $gz, $type);
	return if ($res->[0] > 300 || $res->[0] < 200);
	push @{$res->[1]}, qw(Cache-Control no-transform
				Content-Encoding gzip
				Vary Accept-Encoding);
	$res;
}

sub response ($$$;$) {
	my ($env, $h, $path, $type) = @_;
	$type //= Plack::MIME->mime_type($path) // 'application/octet-stream';
	if ($path !~ /\.gz\z/i) {
		if (my $res = try_gzip_static($env, $h, $path, $type)) {
			return $res;
		}
	}

	my $in;
	if ($env->{REQUEST_METHOD} eq 'HEAD') {
		return r(404) unless -f $path && -r _; # in case it's a FIFO :P
	} else { # GET, callers should've already filtered out other methods
		if (!sysopen($in, $path, O_RDONLY|O_NONBLOCK)) {
			return r(404) if $! == ENOENT || $! == ENOTDIR;
			return r(403) if $! == EACCES;
			return r(500);
		}
		return r(404) unless -f $in;
	}
	my $size = -s _; # bare "_" reuses "struct stat" from "-f" above
	my $mtime = time2str((stat(_))[9]);

	if (my $ims = $env->{HTTP_IF_MODIFIED_SINCE}) {
		return [ 304, [], [] ] if $mtime eq $ims;
	}

	my $len = $size;
	my $code = 200;
	push @$h, 'Content-Type', $type;
	my $off = 0;
	if (($env->{HTTP_RANGE} || '') =~ /\bbytes=([0-9]*)-([0-9]*)\z/) {
		($code, $off, $len) = setup_range($env, $in, $h, $1, $2, $size);
		return $code if ref($code);
	}
	push @$h, 'Content-Length', $len, 'Last-Modified', $mtime;
	[ $code, $h, $in ? getline_response($env, $in, $off, $len, $path) : [] ]
}

# called by PSGI servers on each response chunk:
sub getline {
	my ($self) = @_;

	# avoid buffering, by becoming the buffer! (public-inbox-httpd)
	if (my $tmpio = delete $self->{bypass}) {
		my $http = pop @$tmpio; # PublicInbox::HTTP
		push @{$http->{wbuf}}, $tmpio; # [ $in, $off, $len ]
		$http->flush_write;
		return; # undef, EOF
	}

	# generic PSGI runs this:
	my $len = $self->{len} or return; # undef, tells server we're done
	my $n = 8192;
	$n = $len if $len < $n;
	sysseek($self->{in}, $self->{off}, SEEK_SET) or
			die "sysseek ($self->{path}): $!";
	my $r = sysread($self->{in}, my $buf, $n);
	if (defined $r && $r > 0) { # success!
		$self->{len} = $len - $r;
		$self->{off} += $r;
		return $buf;
	}
	my $m = defined $r ? "EOF with $len bytes left" : "read error: $!";
	die "$self->{path} $m, dropping client socket\n";
}

sub close {} # noop, called by PSGI server, just let everything go out-of-scope

# OO interface for use as a Plack app
sub new {
	my ($class, %opt) = @_;
	my $index = $opt{'index'} // [ 'index.html' ];
	$index = [ $index ] if defined($index) && ref($index) ne 'ARRAY';
	$index = undef if scalar(@$index) == 0;
	my $style = $opt{style};
	if (defined $style) {
		$style = \$style unless ref($style);
	}
	my $docroot = $opt{docroot};
	die "`docroot' not set" unless defined($docroot) && $docroot ne '';
	bless {
		docroot => $docroot,
		index => $index,
		autoindex => $opt{autoindex},
		style => $style // \$STYLE,
	}, $class;
}

# PATH_INFO is decoded, and we want the undecoded original
my %path_re_cache;
sub path_info_raw ($) {
	my ($env) = @_;
	my $sn = $env->{SCRIPT_NAME};
	my $re = $path_re_cache{$sn} //= do {
		$sn = '/'.$sn unless index($sn, '/') == 0;
		$sn =~ s!/\z!!;
		qr!\A(?:https?://[^/]+)?\Q$sn\E(/[^\?\#]+)!;
	};
	$env->{REQUEST_URI} =~ $re ? $1 : $env->{PATH_INFO};
}

sub redirect_slash ($) {
	my ($env) = @_;
	my $url = $env->{'psgi.url_scheme'} . '://';
	my $host_port = $env->{HTTP_HOST} //
		"$env->{SERVER_NAME}:$env->{SERVER_PORT}";
	$url .= $host_port . path_info_raw($env) . '/';
	my $body = "Redirecting to $url\n";
	[ 302, [ qw(Content-Type text/plain), 'Location', $url,
		'Content-Length', length($body) ], [ $body ] ]
}

sub human_size ($) {
	my ($size) = @_;
	my $suffix = '';
	for my $s (qw(K M G T P)) {
		last if $size < 1024;
		$size /= 1024;
		if ($size <= 1024) {
			$suffix = $s;
			last;
		}
	}
	sprintf('%lu', $size).$suffix;
}

# by default, this returns "index.html" if it exists for a given directory
# It'll generate a directory listing, (autoindex).
# May be disabled by setting autoindex => 0
sub dir_response ($$$) {
	my ($self, $env, $fs_path) = @_;
	if (my $index = $self->{'index'}) { # serve index.html or similar
		for my $html (@$index) {
			my $p = $fs_path . $html;
			my $res = response($env, [], $p);
			return $res if $res->[0] != 404;
		}
	}
	return r(404) unless $self->{autoindex};
	opendir(my $dh, $fs_path) or do {
		return r(404) if ($! == ENOENT || $! == ENOTDIR);
		return r(403) if $! == EACCES;
		return r(500);
	};
	my @entries = grep(!/\A\./, readdir($dh));
	$dh = undef;
	my (%dirs, %other, %want_gz);
	my $path_info = $env->{PATH_INFO};
	push @entries, '..' if $path_info ne '/';
	for my $base (@entries) {
		my $href = ascii_html(uri_escape_utf8($base));
		my $name = ascii_html($base);
		my @st = stat($fs_path . $base) or next; # unlikely
		my ($gzipped, $uncompressed, $hsize);
		my $entry = '';
		my $mtime = $st[9];
		if (-d _) {
			$href .= '/';
			$name .= '/';
			$hsize = '-';
			$dirs{"$base\0$mtime"} = \$entry;
		} elsif (-f _) {
			$other{"$base\0$mtime"} = \$entry;
			if ($base !~ /\.gz\z/i) {
				$want_gz{"$base.gz\0$mtime"} = undef;
			}
			$hsize = human_size($st[7]);
		} else {
			next;
		}
		# 54 = 80 - (SP length(strftime(%Y-%m-%d %k:%M)) SP human_size)
		$hsize = sprintf('% 8s', $hsize);
		my $pad = 54 - length($name);
		$pad = 1 if $pad <= 0;
		$entry .= qq(<a\nhref="$href">$name</a>) . (' ' x $pad);
		$mtime = strftime('%Y-%m-%d %k:%M', gmtime($mtime));
		$entry .= $mtime . $hsize;
	}

	# filter out '.gz' files as long as the mtime matches the
	# uncompressed version
	delete(@other{keys %want_gz});
	@entries = ((map { ${$dirs{$_}} } sort keys %dirs),
			(map { ${$other{$_}} } sort keys %other));

	my $path_info_html = ascii_html($path_info);
	my $h = [qw(Content-Type text/html Content-Length), undef];
	my $gzf = gzf_maybe($h, $env);
	$gzf->zmore("<html><head><title>Index of $path_info_html</title>" .
		${$self->{style}} .
		"</head><body><pre>Index of $path_info_html</pre><hr><pre>\n");
	$gzf->zmore(join("\n", @entries));
	my $out = $gzf->zflush("</pre><hr></body></html>\n");
	$h->[3] = length($out);
	[ 200, $h, [ $out ] ]
}

sub call { # PSGI app endpoint
	my ($self, $env) = @_;
	return r(405) if $env->{REQUEST_METHOD} !~ /\A(?:GET|HEAD)\z/;
	my $path_info = $env->{PATH_INFO};
	return r(403) if index($path_info, "\0") >= 0;
	my (@parts) = split(m!/+!, $path_info, -1);
	return r(403) if grep(/\A(?:\.\.)\z/, @parts) || $parts[0] ne '';

	my $fs_path = join('/', $self->{docroot}, @parts);
	return dir_response($self, $env, $fs_path) if $parts[-1] eq '';

	my $res = response($env, [], $fs_path);
	$res->[0] == 404 && -d $fs_path ? redirect_slash($env) : $res;
}

1;
