#!/usr/bin/perl -w
# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use IO::Handle;
use PublicInbox::WWW;
use CGI qw/-nosticky/;
our $NO_SCRIPT_NAME;
our %HTTP_CODES;
BEGIN {
	$NO_SCRIPT_NAME = 1 if $ENV{NO_SCRIPT_NAME};
	if ($ENV{MOD_PERL}) {
		CGI->compile;
		PublicInbox::WWW->preload;
	}

	%HTTP_CODES = (
		200 => 'OK',
		300 => 'Multiple Choices',
		301 => 'Moved Permanently',
		302 => 'Found',
		404 => 'Not Found',
		405 => 'Method Not Allowed',
		501 => 'Not Implemented',
	);
}

# some servers (Ruby webrick) include scheme://host[:port] here,
# which confuses CGI.pm when generating self_url.
# RFC 3875 does not mention REQUEST_URI at all,
# so nuke it since CGI.pm functions without it.
delete $ENV{REQUEST_URI};
$ENV{SCRIPT_NAME} = '' if $NO_SCRIPT_NAME;
my $req = CGI->new;
my $ret = PublicInbox::WWW::run($req, $req->request_method);

my $out = select;
$out->binmode;

if (ref($ret) eq 'CODE') {
	$ret->(*dump_header);
} else {
	my ($status, $headers, $body) = @$ret;

	dump_header([$status, $headers])->write($body->[0]);
}

sub dump_header {
	my ($res) = @_;
	my $fh = select;
	my ($status, $headers) = @$res;
	$fh->write("Status: $status $HTTP_CODES{$status}\r\n");
	my @tmp = @$headers;
	while (my ($k, $v) = splice(@tmp, 0, 2)) {
		$fh->write("$k: $v\r\n");
	}
	$fh->write("\r\n");
	$fh;
}
