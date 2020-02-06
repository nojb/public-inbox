#!/usr/bin/perl -w
# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>
#
# PublicInbox::Cgit may be used independently of WWW.
#
# Usage:
#	plackup -I lib -o 127.0.0.1 -R lib -r examples/cgit.psgi
use strict;
use warnings;
use Plack::Builder;
use PublicInbox::Cgit;
use PublicInbox::Config;
my $pi_config = PublicInbox::Config->new;
my $cgit = PublicInbox::Cgit->new($pi_config);

builder {
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
	sub { $cgit->call($_[0]) }
}
