# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# wraps a listen socket for HTTP and links it to the PSGI app in
# public-inbox-httpd
package PublicInbox::HTTPD;
use v5.10.1;
use strict;
use Plack::Util ();
use Plack::Builder;
use PublicInbox::HTTP;
use PublicInbox::HTTPD::Async;

sub pi_httpd_async { PublicInbox::HTTPD::Async->new(@_) }

sub new {
	my ($class, $sock, $app, $client) = @_;
	my $n = getsockname($sock) or die "not a socket: $sock $!\n";
	my ($host, $port) = PublicInbox::Daemon::host_with_port($n);

	my %env = (
		SERVER_NAME => $host,
		SERVER_PORT => $port,
		SCRIPT_NAME => '',
		'psgi.version' => [ 1, 1 ],
		'psgi.errors' => \*STDERR,
		'psgi.url_scheme' => $client->can('accept_SSL') ?
					'https' : 'http',
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
		# We also check for the truthiness of this to
		# detect when to use async paths for slow blobs
		'pi-httpd.async' => \&pi_httpd_async
	);
	bless { app => $app, env => \%env }, $class;
}

my %httpds; # per-listen-FD mapping for HTTPD->{env}->{SERVER_<NAME|PORT>}
my $default_app; # ugh...

sub refresh {
	if (@main::ARGV) {
		eval { $default_app = Plack::Util::load_psgi(@ARGV) };
		if ($@) {
			die $@,
"$0 runs in /, command-line paths must be absolute\n";
		}
	} else {
		require PublicInbox::WWW;
		my $www = PublicInbox::WWW->new;
		$www->preload;
		$default_app = builder {
			eval { enable 'ReverseProxy' };
			$@ and warn <<EOM;
Plack::Middleware::ReverseProxy missing,
URL generation for redirects may be wrong if behind a reverse proxy
EOM
			enable 'Head';
			sub { $www->call(@_) };
		};
	}
	%httpds = (); # invalidate cache
}

sub post_accept { # Listener->{post_accept}
	my ($client, $addr, $srv) = @_; # $_[3] - tls_wrap (unused)
	my $httpd = $httpds{fileno($srv)} //=
				__PACKAGE__->new($srv, $default_app, $client);
	PublicInbox::HTTP->new($client, $addr, $httpd),
}

1;
