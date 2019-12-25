# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# wrapper for cgit(1) and git-http-backend(1) for browsing and
# serving git code repositories.  Requires 'publicinbox.cgitrc'
# directive to be set in the public-inbox config file.

package PublicInbox::Cgit;
use strict;
use PublicInbox::GitHTTPBackend;
# not bothering with Exporter for a one-off
*r = *PublicInbox::GitHTTPBackend::r;
*input_prepare = *PublicInbox::GitHTTPBackend::input_prepare;
*parse_cgi_headers = *PublicInbox::GitHTTPBackend::parse_cgi_headers;
*serve = *PublicInbox::GitHTTPBackend::serve;
*static_result = *PublicInbox::GitHTTPBackend::static_result;
use warnings;
use PublicInbox::Qspawn;
use Plack::MIME;

sub locate_cgit ($) {
	my ($pi_config) = @_;
	my $cgit_bin = $pi_config->{'publicinbox.cgitbin'};
	my $cgit_data = $pi_config->{'publicinbox.cgitdata'};

	# /var/www/htdocs/cgit is the default install path from cgit.git
	# /usr/{lib,share}/cgit is where Debian puts cgit
	# TODO: check other distros for common paths
	unless (defined $cgit_bin) {
		foreach (qw(/var/www/htdocs/cgit /usr/lib/cgit)) {
			my $x = "$_/cgit.cgi";
			next unless -x $x;
			$cgit_bin = $x;
			last;
		}
	}
	unless (defined $cgit_data) {
		my @dirs = qw(/var/www/htdocs/cgit /usr/share/cgit);

		# local installs of cgit from source have
		# CGIT_SCRIPT_PATH==CGIT_DATA_PATH by default,
		# so we can usually infer the cgit_data path from cgit_bin
		if (defined($cgit_bin) && $cgit_bin =~ m!\A(.+?)/[^/]+\z!) {
			unshift @dirs, $1 if -d $1;
		}
		foreach my $d (@dirs) {
			my $f = "$d/cgit.css";
			next unless -f $f;
			$cgit_data = $d;
			last;
		}
	}
	($cgit_bin, $cgit_data);
}

sub new {
	my ($class, $pi_config) = @_;
	my ($cgit_bin, $cgit_data) = locate_cgit($pi_config);

	my $self = bless {
		cmd => [ $cgit_bin ],
		cgit_data => $cgit_data,
		pi_config => $pi_config,
	}, $class;

	$pi_config->each_inbox(sub {}); # fill in -code_repos mapped to inboxes

	# some cgit repos may not be mapped to inboxes, so ensure those exist:
	my $code_repos = $pi_config->{-code_repos};
	foreach my $k (keys %$pi_config) {
		$k =~ /\Acoderepo\.(.+)\.dir\z/ or next;
		my $dir = $pi_config->{$k};
		$code_repos->{$1} ||= PublicInbox::Git->new($dir);
	}
	while (my ($nick, $repo) = each %$code_repos) {
		$self->{"\0$nick"} = $repo;
	}
	my $cgit_static = $pi_config->{-cgit_static};
	my $static = join('|', map { quotemeta $_ } keys %$cgit_static);
	$self->{static} = qr/\A($static)\z/;
	$self;
}

# only what cgit cares about:
my @PASS_ENV = qw(
	HTTP_HOST
	QUERY_STRING
	REQUEST_METHOD
	SCRIPT_NAME
	SERVER_NAME
	SERVER_PORT
	HTTP_COOKIE
	HTTP_REFERER
	CONTENT_LENGTH
);
# XXX: cgit filters may care about more variables...

sub cgit_parse_hdr { # {parse_hdr} for Qspawn
	my ($r, $bref) = @_;
	my $res = parse_cgi_headers($r, $bref) or return; # incomplete
	$res;
}

sub call {
	my ($self, $env) = @_;
	my $path_info = $env->{PATH_INFO};
	my $cgit_data;

	# handle requests without spawning cgit iff possible:
	if ($path_info =~ m!\A/(.+?)/($PublicInbox::GitHTTPBackend::ANY)\z!ox) {
		my ($nick, $path) = ($1, $2);
		if (my $git = $self->{"\0$nick"}) {
			return serve($env, $git, $path);
		}
	} elsif ($path_info =~ m!$self->{static}! &&
		 defined($cgit_data = $self->{cgit_data})) {
		my $f = $1;
		my $type = Plack::MIME->mime_type($f);
		return static_result($env, [], $cgit_data.$f, $type);
	}

	my $cgi_env = { PATH_INFO => $path_info };
	foreach (@PASS_ENV) {
		defined(my $v = $env->{$_}) or next;
		$cgi_env->{$_} = $v;
	}
	$cgi_env->{'HTTPS'} = 'on' if $env->{'psgi.url_scheme'} eq 'https';

	my $rdr = input_prepare($env) or return r(500);
	my $qsp = PublicInbox::Qspawn->new($self->{cmd}, $cgi_env, $rdr);
	my $limiter = $self->{pi_config}->limiter('-cgit');
	$qsp->psgi_return($env, $limiter, \&cgit_parse_hdr);
}

1;
