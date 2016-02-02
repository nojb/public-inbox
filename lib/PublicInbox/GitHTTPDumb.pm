# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# when no endpoints match, fallback to this and serve a static file
# This can serve Smart HTTP in the future.
package PublicInbox::GitHTTPDumb;
use strict;
use warnings;
use Fcntl qw(:seek);

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

sub r {
	[ $_[0] , [qw(Content-Type text/plain Content-Length 0) ], [] ]
}

sub serve {
	my ($cgi, $git, $path) = @_;
	my $type;
	if ($path =~ /\A(?:$BIN)\z/o) {
		$type = 'application/octet-stream';
	} elsif ($path =~ /\A(?:$TEXT)\z/o) {
		$type = 'text/plain';
	} else {
		return r(404);
	}
	my $f = "$git->{git_dir}/$path";
	return r(404) unless -f $f && -r _;
	my @st = stat(_);
	my $size = $st[7];

	# TODO: If-Modified-Since and Last-Modified
	open my $in, '<', $f or return r(404);
	my $code = 200;
	my $len = $size;
	my @h;

	my $env = $cgi->{env} || \%ENV;
	my $range = $env->{HTTP_RANGE};
	if (defined $range && $range =~ /\bbytes=(\d*)-(\d*)\z/) {
		($code, $len) = prepare_range($cgi, $in, \@h, $1, $2, $size);
		if ($code == 416) {
			push @h, 'Content-Range', "bytes */$size";
			return [ 416, \@h, [] ];
		}
	}

	push @h, 'Content-Type', $type, 'Content-Length', $len;
	sub {
		my ($res) = @_; # Plack callback
		my $fh = $res->([ $code, \@h ]);
		my $buf;
		my $n = 8192;
		while ($len > 0) {
			$n = $len if $len < $n;
			my $r = read($in, $buf, $n);
			last if (!defined($r) || $r <= 0);
			$len -= $r;
			$fh->write($buf);
		}
		$fh->close;
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
			seek($in, $beg, SEEK_SET) or return [ 500, [], [] ];
			push @$h, qw(Accept-Ranges bytes Content-Range);
			push @$h, "bytes $beg-$end/$size";

			# FIXME: Plack::Middleware::Deflater bug?
			if (my $env = $cgi->{env}) {
				$env->{'psgix.no-compress'} = 1;
			}
		}
	}
	($code, $len);
}

1;
