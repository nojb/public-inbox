# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# HTML body stream for which yields getline+close methods for
# generic PSGI servers and callbacks for public-inbox-httpd.
#
# See PublicInbox::GzipFilter parent class for more info.
package PublicInbox::WwwStream;
use strict;
use parent qw(Exporter PublicInbox::GzipFilter);
our @EXPORT_OK = qw(html_oneshot);
use bytes (); # length
use PublicInbox::Hval qw(ascii_html prurl ts2str);
our $TOR_URL = 'https://www.torproject.org/';
our $CODE_URL = [ qw(http://ou63pmih66umazou.onion/public-inbox.git
	https://public-inbox.org/public-inbox.git) ];

sub base_url ($) {
	my $ctx = shift;
	my $base_url = $ctx->{ibx}->base_url($ctx->{env});
	chop $base_url; # no trailing slash for clone
	$base_url;
}

sub init {
	my ($ctx, $cb) = @_;
	$ctx->{cb} = $cb;
	$ctx->{base_url} = base_url($ctx);
	bless $ctx, __PACKAGE__;
}

sub async_eml { # for async_blob_cb
	my ($ctx, $eml) = @_;
	$ctx->{http_out}->write($ctx->translate($ctx->{cb}->($ctx, $eml)));
}

sub html_top ($) {
	my ($ctx) = @_;
	my $ibx = $ctx->{ibx};
	my $desc = ascii_html($ibx->description);
	my $title = delete($ctx->{-title_html}) // $desc;
	my $upfx = $ctx->{-upfx} || '';
	my $help = $upfx.'_/text/help';
	my $color = $upfx.'_/text/color';
	my $atom = $ctx->{-atom} || $upfx.'new.atom';
	my $top = "<b>$desc</b>";
	if (my $t_max = $ctx->{-t_max}) {
		$t_max = ts2str($t_max);
		$top = qq(<a\nhref="$upfx?t=$t_max">$top</a>);
	# we had some kind of query, link to /$INBOX/?t=YYYYMMDDhhmmss
	} elsif ($ctx->{qp}->{t}) {
		$top = qq(<a\nhref="./">$top</a>);
	}
	my $links = qq(<a\nhref="$help">help</a> / ).
			qq(<a\nhref="$color">color</a> / ).
			qq(<a\nhref=#mirror>mirror</a> / ).
			qq(<a\nhref="$atom">Atom feed</a>);
	if ($ibx->isrch) {
		my $q_val = delete($ctx->{-q_value_html}) // '';
		$q_val = qq(\nvalue="$q_val") if $q_val ne '';
		# XXX gross, for SearchView.pm
		my $extra = delete($ctx->{-extra_form_html}) // '';
		my $action = $upfx eq '' ? './' : $upfx;
		$top = qq{<form\naction="$action"><pre>$top} .
			  qq{\n<input\nname=q\ntype=text$q_val />} .
			  $extra .
			  qq{<input\ntype=submit\nvalue=search />} .
			  ' ' . $links .
			  q{</pre></form>}
	} else {
		$top = '<pre>' . $top . "\n" . $links . '</pre>';
	}
	"<html><head><title>$title</title>" .
		qq(<link\nrel=alternate\ntitle="Atom feed"\n).
		qq(href="$atom"\ntype="application/atom+xml"/>) .
	        $ctx->{www}->style($upfx) .
		'</head><body>'. $top . (delete($ctx->{-html_tip}) // '');
}

sub coderepos ($) {
	my ($ctx) = @_;
	my $cr = $ctx->{ibx}->{coderepo} // return ();
	my $cfg = $ctx->{www}->{pi_cfg};
	my $upfx = ($ctx->{-upfx} // ''). '../';
	my @ret;
	for my $cr_name (@$cr) {
		my $urls = $cfg->{"coderepo.$cr_name.cgiturl"} // next;
		$ret[0] //= <<EOF;
code repositories for the project(s) associated with this inbox:
EOF
		for (@$urls) {
			# relative or absolute URL?, prefix relative "foo.git"
			# with appropriate number of "../"
			my $u = m!\A(?:[a-z\+]+:)?//! ? $_ : $upfx.$_;
			$u = ascii_html(prurl($ctx->{env}, $u));
			$ret[0] .= qq(\n\t<a\nhref="$u">$u</a>);
		}
	}
	@ret; # may be empty, this sub is called as an arg for join()
}

sub code_footer ($) {
	my ($env) = @_;
	my $u = prurl($env, $CODE_URL);
	qq(AGPL code for this site: git clone <a\nhref="$u">$u</a>)
}

sub _html_end {
	my ($ctx) = @_;
	my $urls = <<EOF;
<a
id=mirror>This inbox may be cloned and mirrored by anyone:</a>
EOF

	my $ibx = $ctx->{ibx};
	my $desc = ascii_html($ibx->description);

	my @urls;
	my $http = $ctx->{base_url};
	my $max = $ibx->max_git_epoch;
	my $dir = (split(m!/!, $http))[-1];
	my %seen = ($http => 1);
	if (defined($max)) { # v2
		for my $i (0..$max) {
			# old epochs my be deleted:
			-d "$ibx->{inboxdir}/git/$i.git" or next;
			my $url = "$http/$i";
			$seen{$url} = 1;
			push @urls, "$url $dir/git/$i.git";
		}
		my $nr = scalar(@urls);
		if ($nr > 1) {
			$urls .= "\n\t# this inbox consists of $nr epochs:";
			$urls[0] .= "\t# oldest";
			$urls[-1] .= "\t# newest";
		}
	} else { # v1
		push @urls, $http;
	}

	# FIXME: epoch splits can be different in other repositories,
	# use the "cloneurl" file as-is for now:
	foreach my $u (@{$ibx->cloneurl}) {
		next if $seen{$u}++;
		push @urls, $u =~ /\Ahttps?:/ ? qq(<a\nhref="$u">$u</a>) : $u;
	}

	$urls .= "\n" . join('', map { "\tgit clone --mirror $_\n" } @urls);
	if (my $addrs = $ibx->{address}) {
		$addrs = join(' ', @$addrs) if ref($addrs) eq 'ARRAY';
		my $v = defined $max ? '-V2' : '-V1';
		$urls .= <<EOF;

	# If you have public-inbox 1.1+ installed, you may
	# initialize and index your mirror using the following commands:
	public-inbox-init $v $ibx->{name} $dir/ $http \\
		$addrs
	public-inbox-index $dir
EOF
	}
	my $cfg_link = ($ctx->{-upfx} // '').'_/text/config/raw';
	$urls .= <<EOF;

Example <a
href="$cfg_link">config snippet</a> for mirrors.
EOF
	my @nntp = map { qq(<a\nhref="$_">$_</a>) } @{$ibx->nntp_url};
	if (@nntp) {
		$urls .= @nntp == 1 ? 'Newsgroup' : 'Newsgroups are';
		$urls .= ' available over NNTP:';
		$urls .= "\n\t" . join("\n\t", @nntp) . "\n";
	}
	if ($urls =~ m!\b[^:]+://\w+\.onion/!) {
		$urls .= " note: .onion URLs require Tor: ";
		$urls .= qq[<a\nhref="$TOR_URL">$TOR_URL</a>];
	}
	'<hr><pre>'.join("\n\n",
		$desc,
		$urls,
		coderepos($ctx),
		code_footer($ctx->{env})
	).'</pre></body></html>';
}

# callback for HTTP.pm (and any other PSGI servers)
sub getline {
	my ($ctx) = @_;
	my $cb = $ctx->{cb} or return;
	while (defined(my $x = $cb->($ctx))) { # x = smsg or scalar non-ref
		if (ref($x)) { # smsg
			my $eml = $ctx->{ibx}->smsg_eml($x) or next;
			$ctx->{smsg} = $x;
			return $ctx->translate($cb->($ctx, $eml));
		} else { # scalar
			return $ctx->translate($x);
		}
	}
	delete $ctx->{cb};
	$ctx->zflush(_html_end($ctx));
}

sub html_oneshot ($$;$) {
	my ($ctx, $code, $sref) = @_;
	my $res_hdr = [ 'Content-Type' => 'text/html; charset=UTF-8',
		'Content-Length' => undef ];
	bless $ctx, __PACKAGE__;
	$ctx->{gz} = PublicInbox::GzipFilter::gz_or_noop($res_hdr, $ctx->{env});
	$ctx->{base_url} //= do {
		$ctx->zmore(html_top($ctx));
		base_url($ctx);
	};
	$ctx->zmore($$sref) if $sref;
	my $bdy = $ctx->zflush(_html_end($ctx));
	$res_hdr->[3] = bytes::length($bdy);
	[ $code, $res_hdr, [ $bdy ] ]
}

sub async_next ($) {
	my ($http) = @_; # PublicInbox::HTTP
	my $ctx = $http->{forward} or return;
	eval {
		if (my $smsg = $ctx->{smsg} = $ctx->{cb}->($ctx)) {
			$ctx->smsg_blob($smsg);
		} else {
			$ctx->{http_out}->write(
					$ctx->translate(_html_end($ctx)));
			$ctx->close; # GzipFilter->close
		}
	};
	warn "E: $@" if $@;
}

sub aresponse {
	my ($ctx, $code, $cb) = @_;
	my $res_hdr = [ 'Content-Type' => 'text/html; charset=UTF-8' ];
	init($ctx, $cb);
	$ctx->psgi_response($code, $res_hdr);
}

1;
