# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provide an HTTP-accessible listing of inboxes.
# Used by PublicInbox::WWW
package PublicInbox::WwwListing;
use strict;
use PublicInbox::Hval qw(ascii_html prurl fmt_ts);
use PublicInbox::Linkify;
use PublicInbox::GzipFilter qw(gzf_maybe);
use PublicInbox::ManifestJsGz;
use bytes (); # bytes::length

sub list_all_i {
	my ($ibx, $arg) = @_;
	my ($list, $hide_key) = @$arg;
	push @$list, $ibx unless $ibx->{-hide}->{$hide_key};
}

sub list_all ($$$) {
	my ($self, $env, $hide_key) = @_;
	my $list = [];
	$self->{pi_config}->each_inbox(\&list_all_i, [ $list, $hide_key ]);
	$list;
}

sub list_match_domain_i {
	my ($ibx, $arg) = @_;
	my ($list, $hide_key, $re) = @$arg;
	if (!$ibx->{-hide}->{$hide_key} && grep(/$re/, @{$ibx->{url}})) {
		push @$list, $ibx;
	}
}

sub list_match_domain ($$$) {
	my ($self, $env, $hide_key) = @_;
	my $list = [];
	my $host = $env->{HTTP_HOST} // $env->{SERVER_NAME};
	$host =~ s/:[0-9]+\z//;
	my $arg = [ $list, $hide_key,
		qr!\A(?:https?:)?//\Q$host\E(?::[0-9]+)?/!i ];
	$self->{pi_config}->each_inbox(\&list_match_domain_i, $arg);
	$list;
}

sub list_404 ($$) { [] }

# TODO: +cgit
my %VALID = (
	all => \&list_all,
	'match=domain' => \&list_match_domain,
	404 => \&list_404,
);

sub set_cb ($$$) {
	my ($pi_config, $k, $default) = @_;
	my $v = $pi_config->{lc $k} // $default;
	$VALID{$v} || do {
		warn <<"";
`$v' is not a valid value for `$k'
$k be one of `all', `match=domain', or `404'

		$VALID{$default};
	};
}

sub new {
	my ($class, $www) = @_;
	my $pi_config = $www->{pi_config};
	bless {
		pi_config => $pi_config,
		style => $www->style("\0"),
		www_cb => set_cb($pi_config, 'publicInbox.wwwListing', 404),
		manifest_cb => set_cb($pi_config, 'publicInbox.grokManifest',
					'match=domain'),
	}, $class;
}

sub ibx_entry {
	my ($mtime, $ibx, $env) = @_;
	my $ts = fmt_ts($mtime);
	my $url = prurl($env, $ibx->{url});
	my $tmp = <<"";
* $ts - $url
  ${\$ibx->description}

	if (defined(my $info_url = $ibx->{infourl})) {
		$tmp .= '  ' . prurl($env, $info_url) . "\n";
	}
	$tmp;
}

sub html ($$) {
	my ($env, $list) = @_;
	my $h = [ 'Content-Type', 'text/html; charset=UTF-8',
			'Content-Length', undef ];
	my $gzf = gzf_maybe($h, $env);
	$gzf->zmore('<html><head><title>' .
				'public-inbox listing</title>' .
				'</head><body><pre>');
	my $code = 404;
	if (@$list) {
		$code = 200;
		# Schwartzian transform since Inbox->modified is expensive
		@$list = sort {
			$b->[0] <=> $a->[0]
		} map { [ $_->modified, $_ ] } @$list;

		my $tmp = join("\n", map { ibx_entry(@$_, $env) } @$list);
		my $l = PublicInbox::Linkify->new;
		$gzf->zmore($l->to_html($tmp));
	} else {
		$gzf->zmore('no inboxes, yet');
	}
	my $out = $gzf->zflush('</pre><hr><pre>'.
				PublicInbox::WwwStream::code_footer($env) .
				'</pre></body></html>');
	$h->[3] = bytes::length($out);
	[ $code, $h, [ $out ] ];
}

# not really a stand-alone PSGI app, but maybe it could be...
sub call {
	my ($self, $env) = @_;

	if ($env->{PATH_INFO} eq '/manifest.js.gz') {
		# grokmirror uses relative paths, so it's domain-dependent
		my $list = $self->{manifest_cb}->($self, $env, 'manifest');
		PublicInbox::ManifestJsGz::response($env, $list);
	} else { # /
		my $list = $self->{www_cb}->($self, $env, 'www');
		html($env, $list);
	}
}

1;
