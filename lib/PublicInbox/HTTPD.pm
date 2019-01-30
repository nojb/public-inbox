# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# wraps a listen socket for HTTP and links it to the PSGI app in
# public-inbox-httpd
package PublicInbox::HTTPD;
use strict;
use warnings;
use Plack::Util;
require PublicInbox::HTTPD::Async;
require PublicInbox::Daemon;

sub pi_httpd_async { PublicInbox::HTTPD::Async->new(@_) }

sub new {
	my ($class, $sock, $app) = @_;
	my $n = getsockname($sock) or die "not a socket: $sock $!\n";
	my ($host, $port) = PublicInbox::Daemon::host_with_port($n);

	my %env = (
		SERVER_NAME => $host,
		SERVER_PORT => $port,
		SCRIPT_NAME => '',
		'psgi.version' => [ 1, 1 ],
		'psgi.errors' => \*STDERR,
		'psgi.url_scheme' => 'http',
		'psgi.nonblocking' => Plack::Util::TRUE,
		'psgi.streaming' => Plack::Util::TRUE,
		'psgi.run_once'	 => Plack::Util::FALSE,
		'psgi.multithread' => Plack::Util::FALSE,
		'psgi.multiprocess' => Plack::Util::TRUE,

		# We don't use this anywhere, but we can support
		# other PSGI apps which might use it:
		'psgix.input.buffered' => Plack::Util::TRUE,

		# XXX unstable API!, only GitHTTPBackend needs
		# this to limit git-http-backend(1) parallelism.
		# The rest of our PSGI code is generic, relying
		# on "pull" model using "getline" to prevent
		# over-buffering.
		'pi-httpd.async' => do {
			no warnings 'once';
			*pi_httpd_async
		},
	);
	bless {
		app => $app,
		env => \%env
	}, $class;
}

1;
