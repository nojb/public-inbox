# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# corner case tests for the generic PSGI server
# Usage: plackup [OPTIONS] /path/to/this/file
use strict;
use warnings;
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
	} elsif (my $fifo = $env->{HTTP_X_CHECK_FIFO}) {
		if ($path eq '/slow-header') {
			return sub {
				open my $f, '<', $fifo or
						die "open $fifo: $!\n";
				my @r = <$f>;
				$_[0]->([200, $h, \@r ]);
			};
		} elsif ($path eq '/slow-body') {
			return sub {
				my $fh = $_[0]->([200, $h]);
				open my $f, '<', $fifo or
						die "open $fifo: $!\n";
				while (defined(my $l = <$f>)) {
					$fh->write($l);
				}
				$fh->close;
			};
		}
	} elsif ($path eq '/host-port') {
		$code = 200;
		push @$body, "$env->{REMOTE_ADDR}:$env->{REMOTE_PORT}";
	} elsif ($path eq '/callback') {
		return sub {
			my ($res) = @_;
			my $buf = "hello world\n";
			push @$h, 'Content-Length', length($buf);
			my $fh = $res->([200, $h]);
			$fh->write($buf);
			$fh->close;
		}
	}

	[ $code, $h, $body ]
};

builder {
	enable 'ContentLength';
	enable 'Head';
	$app;
}
