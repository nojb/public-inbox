#!/usr/bin/perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Usage: plackup [OPTIONS] /path/to/this/file
# A startup command for development which monitors changes:
#	plackup -I lib -o 127.0.0.1 -R lib -r examples/highlight.psgi
#
# .psgi paths may also be passed to public-inbox-httpd(1) for
# production deployments:
#	public-inbox-httpd [OPTIONS] /path/to/examples/highlight.psgi
use strict;
use warnings;
use PublicInbox::WwwHighlight;
use Plack::Builder;
my $hl = PublicInbox::WwwHighlight->new;
builder { sub { $hl->call(@_) }; }
