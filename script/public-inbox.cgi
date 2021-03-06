#!/usr/bin/perl -w
# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ or later <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Enables using PublicInbox::WWW as a CGI script
use strict;
use warnings;
use Plack::Builder;
use Plack::Handler::CGI;
use PublicInbox::WWW;
BEGIN { PublicInbox::WWW->preload if $ENV{MOD_PERL} }
my $www = PublicInbox::WWW->new;
my $have_deflater = eval { require Plack::Middleware::Deflater; 1 };
my $app = builder {
	if ($have_deflater) {
		enable 'Deflater',
			content_type => [ 'text/html', 'text/plain',
					'application/atom+xml' ];
	}

	# Enable to ensure redirects and Atom feed URLs are generated
	# properly when running behind a reverse proxy server which
	# sets the X-Forwarded-Proto request header.
	# See Plack::Middleware::ReverseProxy documentation for details
	# enable 'ReverseProxy';

	enable 'Head';
	sub { $www->call(@_) };
};
Plack::Handler::CGI->new->run($app);
