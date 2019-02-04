#!/usr/bin/perl -w
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
#
# NewsWWW may be used independently of WWW.  This can be useful
# for mapping HTTP/HTTPS requests to the hostname of an NNTP server
# to redirect users to the proper HTTP/HTTPS endpoint for a given
# inbox.  NewsWWW exists because people (or software) can mishandle
# "nntp://" or "news://" URLs as "http://" (or "https://")
#
# Usage:
#	plackup -I lib -o 127.0.0.1 -R lib -r examples/newswww.psgi
use strict;
use warnings;
use Plack::Builder;
use PublicInbox::WWW;
use PublicInbox::NewsWWW;

my $newswww = PublicInbox::NewsWWW->new;

# Optional, (you may drop the "mount '/'" section below)
my $www = PublicInbox::WWW->new;
$www->preload;

builder {
	# HTTP/1.1 requests to "Host: news.example.com" will hit this:
	mount 'http://news.example.com/' => builder {
		enable 'Head';
		sub { $newswww->call($_[0]) };
	};

	# rest of requests will hit this (optional) part for the
	# regular PublicInbox::WWW code:
	# see comments in examples/public-inbox.psgi for more info:
	mount '/' => builder {
		eval {
			enable 'Deflater',
				content_type => [ qw(
					text/html
					text/plain
					application/atom+xml
					)]
		};
		eval { enable 'ReverseProxy' };
		enable 'Head';
		sub { $www->call($_[0]) }
	};
}
