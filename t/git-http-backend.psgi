#!/usr/bin/perl -w
# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use PublicInbox::GitHTTPBackend;
use PublicInbox::Git;
use Plack::Builder;
use Plack::Request;
use BSD::Resource qw(getrusage);
my $git_dir = $ENV{GIANT_GIT_DIR} or die 'GIANT_GIT_DIR not defined in env';
my $git = PublicInbox::Git->new($git_dir);
builder {
	enable 'Head';
	sub {
		my ($env) = @_;
		my $pr = Plack::Request->new($env);
		if ($pr->path_info =~ m!\A/(.+)\z!s) {
			PublicInbox::GitHTTPBackend::serve($pr, $git, $1);
		} else {
			my $ru = getrusage();
			my $b = $ru->maxrss . "\n";
			[ 200, [ qw(Content-Type text/plain Content-Length),
				 length($b) ], [ $b ] ]
		}
	}
}
