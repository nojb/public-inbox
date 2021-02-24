# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provide an HTTP-accessible listing of inboxes.
# Used by PublicInbox::WWW
package PublicInbox::WwwListing;
use strict;
use PublicInbox::Hval qw(prurl fmt_ts);
use PublicInbox::Linkify;
use PublicInbox::GzipFilter qw(gzf_maybe);
use PublicInbox::ConfigIter;
use PublicInbox::WwwStream;
use bytes (); # bytes::length

sub ibx_entry {
	my ($ctx, $ibx) = @_;
	my $mtime = $ibx->modified;
	my $ts = fmt_ts($mtime);
	my $url = prurl($ctx->{env}, $ibx->{url});
	my $tmp = <<"";
* $ts - $url
  ${\$ibx->description}

	if (defined(my $info_url = $ibx->{infourl})) {
		$tmp .= '  ' . prurl($ctx->{env}, $info_url) . "\n";
	}
	push @{$ctx->{-list}}, [ $mtime, $tmp ];
}

sub list_match_i { # ConfigIter callback
	my ($cfg, $section, $re, $ctx) = @_;
	if (defined($section)) {
		return if $section !~ m!\Apublicinbox\.([^/]+)\z!;
		my $ibx = $cfg->lookup_name($1) or return;
		if (!$ibx->{-hide}->{$ctx->hide_key} &&
					grep(/$re/, @{$ibx->{url}})) {
			$ctx->ibx_entry($ibx);
		}
	} else { # undef == "EOF"
		$ctx->{-wcb}->($ctx->psgi_triple);
	}
}

sub url_regexp {
	my ($ctx, $key, $default) = @_;
	$key //= 'publicInbox.wwwListing';
	$default //= '404';
	my $v = $ctx->{www}->{pi_cfg}->{lc $key} // $default;
again:
	if ($v eq 'match=domain') {
		my $h = $ctx->{env}->{HTTP_HOST} // $ctx->{env}->{SERVER_NAME};
		$h =~ s/:[0-9]+\z//;
		qr!\A(?:https?:)?//\Q$h\E(?::[0-9]+)?/!i;
	} elsif ($v eq 'all') {
		qr/./;
	} elsif ($v eq '404') {
		undef;
	} else {
		warn <<EOF;
`$v' is not a valid value for `$key'
$key be one of `all', `match=domain', or `404'
EOF
		$v = $default; # 'match=domain' or 'all'
		goto again;
	}
}

sub hide_key { 'www' }

sub response {
	my ($class, $ctx) = @_;
	bless $ctx, $class;
	if (my $ALL = $ctx->{www}->{pi_cfg}->ALL) {
		$ALL->misc->reopen;
	}
	my $re = $ctx->url_regexp or return $ctx->psgi_triple;
	my $iter = PublicInbox::ConfigIter->new($ctx->{www}->{pi_cfg},
						\&list_match_i, $re, $ctx);
	sub {
		$ctx->{-wcb} = $_[0]; # HTTP server callback
		$ctx->{env}->{'pi-httpd.async'} ?
				$iter->event_step : $iter->each_section;
	}
}

sub psgi_triple {
	my ($ctx) = @_;
	my $h = [ 'Content-Type', 'text/html; charset=UTF-8',
			'Content-Length', undef ];
	my $gzf = gzf_maybe($h, $ctx->{env});
	$gzf->zmore('<html><head><title>' .
				'public-inbox listing</title>' .
				'</head><body><pre>');
	my $code = 404;
	if (my $list = $ctx->{-list}) {
		$code = 200;
		# sort by ->modified
		@$list = map { $_->[1] } sort { $b->[0] <=> $a->[0] } @$list;
		$list = join("\n", @$list);
		my $l = PublicInbox::Linkify->new;
		$gzf->zmore($l->to_html($list));
	} else {
		$gzf->zmore('no inboxes, yet');
	}
	my $out = $gzf->zflush('</pre><hr><pre>'.
			PublicInbox::WwwStream::code_footer($ctx->{env}) .
			'</pre></body></html>');
	$h->[3] = bytes::length($out);
	[ $code, $h, [ $out ] ];
}

1;
