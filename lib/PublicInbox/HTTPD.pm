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

# we have a different env for ever listener socket for
# SERVER_NAME, SERVER_PORT and psgi.url_scheme
# envs: listener FD => PSGI env
sub new { bless { envs => {}, err => \*STDERR }, __PACKAGE__ }

# this becomes {srv_env} in PublicInbox::HTTP
sub env_for ($$$) {
	my ($self, $srv, $client) = @_;
	my $n = getsockname($srv) or die "not a socket: $srv $!\n";
	my ($host, $port) = PublicInbox::Daemon::host_with_port($n);
	{
		SERVER_NAME => $host,
		SERVER_PORT => $port,
		SCRIPT_NAME => '',
		'psgi.version' => [ 1, 1 ],
		'psgi.errors' => $self->{err},
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
		'pi-httpd.async' => \&pi_httpd_async,
		'pi-httpd.app' => $self->{app},
		'pi-httpd.warn_cb' => $self->{warn_cb},
	}
}

sub refresh_groups {
	my ($self) = @_;
	my $app;
	$self->{psgi} //= $main::ARGV[0] if @main::ARGV;
	if ($self->{psgi}) {
		eval { $app = Plack::Util::load_psgi($self->{psgi}) };
		die $@, <<EOM if $@;
$0 runs in /, command-line paths must be absolute
EOM
	} else {
		require PublicInbox::WWW;
		my $www = PublicInbox::WWW->new;
		$www->preload;
		$app = builder {
			eval { enable 'ReverseProxy' };
			$@ and warn <<EOM;
Plack::Middleware::ReverseProxy missing,
URL generation for redirects may be wrong if behind a reverse proxy
EOM
			enable 'Head';
			sub { $www->call(@_) };
		};
	}
	$_->{'pi-httpd.app'} = $app for values %{$self->{envs}};
	$self->{app} = $app;
}

sub post_accept_cb { # for Listener->{post_accept}
	my ($self) = @_;
	sub {
		my ($client, $addr, $srv) = @_; # $_[4] - tls_wrap (unused)
		PublicInbox::HTTP->new($client, $addr,
				$self->{envs}->{fileno($srv)} //=
					env_for($self, $srv, $client));
	}
}

1;
