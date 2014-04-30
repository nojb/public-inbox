#!/usr/bin/perl -w
# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# Note: this is part of our test suite, update t/plack.t if this changes
use strict;
use warnings;
require PublicInbox::WWW;
require Plack::Request;
sub {
	my $req = Plack::Request->new(@_);
	PublicInbox::WWW::run($req, $req->method);
};
