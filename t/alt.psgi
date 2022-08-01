# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
use warnings;
use Plack::Builder;
my $pi_config = $ENV{PI_CONFIG} // 'unset'; # capture ASAP
my $app = sub {
	my ($env) = @_;
	$env->{'psgi.errors'}->print("ALT\n");
	[ 200, ['Content-Type', 'text/plain'], [ $pi_config ] ]
};

builder {
	enable 'ContentLength';
	enable 'Head';
	$app;
}
