# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# corner case tests for the generic PSGI server
# Usage: plackup [OPTIONS] /path/to/this/file
use strict;
use warnings;
use Plack::Request;
use Plack::Builder;
require Digest::SHA;
my $app = sub {
	my ($env) = @_;
	my $path = $env->{PATH_INFO};
	my $in = $env->{'psgi.input'};
	my $actual = -s $in;
	my $code = 500;
	my $h = [ 'Content-Type' => 'text/plain' ];
	my $body = [];
	if ($path eq '/sha1') {
		my $sha1 = Digest::SHA->new('SHA-1');
		my $buf;
		while (1) {
			my $r = $in->read($buf, 4096);
			die "read err: $!" unless defined $r;
			last if $r == 0;
			$sha1->add($buf);
		}
		$code = 200;
		push @$body, $sha1->hexdigest;
	}
	[ $code, $h, $body ]
};

builder {
	enable 'ContentLength';
	enable 'Head';
	$app;
}
