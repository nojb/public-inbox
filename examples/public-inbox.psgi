#!/usr/bin/perl -w
# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# Note: this is part of our test suite, update t/plack.t if this changes
# Usage: plackup [OPTIONS] /path/to/this/file
# A startup command for development which monitors changes:
#	plackup -I lib -o 127.0.0.1 -R lib -r examples/public-inbox.psgi
use strict;
use warnings;
use PublicInbox::WWW;
PublicInbox::WWW->preload;
use Plack::Request;
use Plack::Builder;
my $www = PublicInbox::WWW->new;
builder {
	enable 'Chunked';
	eval {
		enable 'Deflater',
			content_type => [ qw(
				text/html
				text/plain
				application/atom+xml
				)]
	};
	$@ and warn
"Plack::Middleware::Deflater missing, bandwidth will be wasted\n";

	# Enable to ensure redirects and Atom feed URLs are generated
	# properly when running behind a reverse proxy server which
	# sets X-Forwarded-For and X-Forwarded-Proto request headers.
	# See Plack::Middleware::ReverseProxy documentation for details
	eval { enable 'ReverseProxy' };
	$@ and warn
"Plack::Middleware::ReverseProxy missing,\n",
"URL generation for redirects may be wrong if behind a reverse proxy\n";

	# Optional: Log timing information for requests to track performance.
	# Logging to STDOUT is recommended since public-inbox-httpd knows
	# how to reopen it via SIGUSR1 after log rotation.
	# enable 'AccessLog::Timed',
	#	logger => sub { syswrite(STDOUT, $_[0]) },
	#	format => '%t "%r" %>s %b %D';

	enable 'Head';
	sub { $www->call(@_) };
}
