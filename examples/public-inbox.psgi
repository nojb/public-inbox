#!/usr/bin/perl -w
# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# Note: this is part of our test suite, update t/plack.t if this changes
# Usage: plackup [OPTIONS] /path/to/this/file
use strict;
use warnings;
use PublicInbox::WWW;
PublicInbox::WWW->preload;
use Plack::Request;
use Plack::Builder;
builder {
	enable "Deflater",
		content_type => [ 'text/html', 'text/plain',
				'application/atom+xml' ];
	enable "Head";
	sub {
		my $req = Plack::Request->new(@_);
		PublicInbox::WWW::run($req, $req->method);
	}
}
