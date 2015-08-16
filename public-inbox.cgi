#!/usr/bin/perl -w
# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
require PublicInbox::WWW;
use CGI qw/-nosticky/;
our $NO_SCRIPT_NAME;
BEGIN {
	$NO_SCRIPT_NAME = 1 if $ENV{NO_SCRIPT_NAME};
	CGI->compile if $ENV{MOD_PERL};
}

# some servers (Ruby webrick) include scheme://host[:port] here,
# which confuses CGI.pm when generating self_url.
# RFC 3875 does not mention REQUEST_URI at all,
# so nuke it since CGI.pm functions without it.
delete $ENV{REQUEST_URI};
$ENV{SCRIPT_NAME} = '' if $NO_SCRIPT_NAME;
my $req = CGI->new;
my $ret = PublicInbox::WWW::run($req, $req->request_method);
binmode STDOUT;
if (@ARGV && $ARGV[0] eq 'static') {
	print $ret->[2]->[0]; # only show the body
} else { # CGI
	my ($status, $headers, $body) = @$ret;
	my %codes = (
		200 => 'OK',
		301 => 'Moved Permanently',
		404 => 'Not Found',
		405 => 'Method Not Allowed',
		501 => 'Not Implemented',
	);

	print "Status: $status $codes{$status}\r\n";
	my @tmp = @$headers;
	while (my ($k, $v) = splice(@tmp, 0, 2)) {
		print "$k: $v\r\n";
	}
	print "\r\n", $body->[0];
}
