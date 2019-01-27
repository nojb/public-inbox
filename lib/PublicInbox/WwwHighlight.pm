# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Standalone PSGI app to provide syntax highlighting as-a-service
# via "highlight" Perl module ("libhighlight-perl" in Debian).
#
# This allows exposing highlight as a persistent HTTP service for
# other scripts via HTTP PUT requests.  PATH_INFO will be used
# as a hint for detecting the language for highlight.
#
# The following example using curl(1) will do the right thing
# regarding the file extension:
#
#   curl -HExpect: -T /path/to/file http://example.com/
#
# You can also force a file extension by giving a path
# (in this case, "c") via:
#
#   curl -HExpect: -T /path/to/file http://example.com/x.c

package PublicInbox::WwwHighlight;
use strict;
use warnings;
use HTTP::Status qw(status_message);
use parent qw(PublicInbox::HlMod);

# TODO: support highlight(1) for distros which don't package the
# SWIG extension.  Also, there may be admins who don't want to
# have ugly SWIG-generated code in a long-lived Perl process.

sub r ($) {
	my ($code) = @_;
	my $msg = status_message($code);
	my $len = length($msg);
	[ $code, [qw(Content-Type text/plain Content-Length), $len], [$msg] ]
}

# another slurp API hogging up all my memory :<
# This is capped by whatever the PSGI server allows,
# $ENV{GIT_HTTP_MAX_REQUEST_BUFFER} for PublicInbox::HTTP (10 MB)
sub read_in_full ($) {
	my ($env) = @_;

	my $in = $env->{'psgi.input'};
	my $off = 0;
	my $buf = '';
	my $len = $env->{CONTENT_LENGTH} || 8192;
	while (1) {
		my $r = $in->read($buf, $len, $off);
		last unless defined $r;
		return \$buf if $r == 0;
		$off += $r;
	}
	$env->{'psgi.errors'}->print("input read error: $!\n");
	undef;
}

# entry point for PSGI
sub call {
	my ($self, $env) = @_;
	my $req_method = $env->{REQUEST_METHOD};

	return r(405) if $req_method ne 'PUT';

	my $bref = read_in_full($env) or return r(500);
	$bref = $self->do_hl($bref, $env->{PATH_INFO});

	my $h = [ 'Content-Type', 'text/html; charset=UTF-8' ];
	push @$h, 'Content-Length', bytes::length($$bref);

	[ 200, $h, [ $$bref ] ]
}

1;
