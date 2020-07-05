# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# HTML body stream for which yields getline+close methods
#
# public-inbox-httpd favors "getline" response bodies to take a
# "pull"-based approach to feeding slow clients (as opposed to a
# more common "push" model)
package PublicInbox::WwwStream;
use strict;
use parent qw(Exporter);
our @EXPORT_OK = qw(html_oneshot);
use bytes (); # length
use PublicInbox::Hval qw(ascii_html prurl);
use PublicInbox::GzipFilter qw(gzf_maybe);
our $TOR_URL = 'https://www.torproject.org/';
our $CODE_URL = 'https://public-inbox.org/public-inbox.git';

# noop for HTTP.pm (and any other PSGI servers)
sub close {}

sub base_url ($) {
	my $ctx = shift;
	my $base_url = $ctx->{-inbox}->base_url($ctx->{env});
	chop $base_url; # no trailing slash for clone
	$base_url;
}

sub init {
	my ($ctx, $cb) = @_;
	$ctx->{cb} = $cb;
	$ctx->{base_url} = base_url($ctx);
	bless $ctx, __PACKAGE__;
}

sub response {
	my ($ctx, $code, $cb) = @_;
	my $h = [ 'Content-Type', 'text/html; charset=UTF-8' ];
	init($ctx, $cb);
	$ctx->{gzf} = gzf_maybe($h, $ctx->{env});
	[ $code, $h, $ctx ]
}

sub html_top ($) {
	my ($ctx) = @_;
	my $ibx = $ctx->{-inbox};
	my $desc = ascii_html($ibx->description);
	my $title = delete($ctx->{-title_html}) // $desc;
	my $upfx = $ctx->{-upfx} || '';
	my $help = $upfx.'_/text/help';
	my $color = $upfx.'_/text/color';
	my $atom = $ctx->{-atom} || $upfx.'new.atom';
	my $top = "<b>$desc</b>";
	my $links = "<a\nhref=\"$help\">help</a> / ".
			"<a\nhref=\"$color\">color</a> / ".
			"<a\nhref=\"$atom\">Atom feed</a>";
	if ($ibx->search) {
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

sub code_footer ($) {
	my ($env) = @_;
	my $u = prurl($env, $CODE_URL);
	qq(AGPL code for this site: git clone <a\nhref="$u">$u</a>)
}

sub _html_end {
	my ($ctx) = @_;
	my $urls = 'Archives are clonable:';
	my $ibx = $ctx->{-inbox};
	my $desc = ascii_html($ibx->description);

	my @urls;
	my $http = $ctx->{base_url};
	my $max = $ibx->max_git_epoch;
	my $dir = (split(m!/!, $http))[-1];
	my %seen = ($http => 1);
	if (defined($max)) { # v2
		for my $i (0..$max) {
			# old parts my be deleted:
			-d "$ibx->{inboxdir}/git/$i.git" or next;
			my $url = "$http/$i";
			$seen{$url} = 1;
			push @urls, "$url $dir/git/$i.git";
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

	if (defined($max) || scalar(@urls) > 1) {
		$urls .= "\n" .
			join("\n", map { "\tgit clone --mirror $_" } @urls);
	} else {
		$urls .= " git clone --mirror $urls[0]";
	}
	if (defined $max) {
		my $addrs = $ibx->{address};
		$addrs = join(' ', @$addrs) if ref($addrs) eq 'ARRAY';
		$urls .=  <<EOF


	# If you have public-inbox 1.1+ installed, you may
	# initialize and index your mirror using the following commands:
	public-inbox-init -V2 $ibx->{name} $dir/ $http \\
		$addrs
	public-inbox-index $dir
EOF
	} else { # v1
		$urls .= "\n";
	}

	my $cfg_link = ($ctx->{-upfx} // '').'_/text/config/raw';
	$urls .= qq(\nExample <a\nhref="$cfg_link">config snippet</a> for mirrors\n);
	my @nntp = map { qq(<a\nhref="$_">$_</a>) } @{$ibx->nntp_url};
	if (@nntp) {
		$urls .= "\n";
		$urls .= @nntp == 1 ? 'Newsgroup' : 'Newsgroups are';
		$urls .= ' available over NNTP:';
		$urls .= "\n\t" . join("\n\t", @nntp) . "\n";
	}
	if ($urls =~ m!\b[^:]+://\w+\.onion/!) {
		$urls .= "\n note: .onion URLs require Tor: ";
		$urls .= qq[<a\nhref="$TOR_URL">$TOR_URL</a>];
	}
	'<hr><pre>'.join("\n\n",
		$desc,
		$urls,
		code_footer($ctx->{env})
	).'</pre></body></html>';
}

# callback for HTTP.pm (and any other PSGI servers)
sub getline {
	my ($ctx) = @_;
	my $cb = $ctx->{cb};
	my $buf = $cb->($ctx) if $cb;
	$buf //= delete($ctx->{cb}) ? _html_end($ctx) : undef;

	# gzf may be GzipFilter, `undef' or `0'
	my $gzf = $ctx->{gzf} or return $buf;

	return $gzf->translate($buf) if defined $buf;
	$ctx->{gzf} = 0; # next call to ->getline returns $buf (== undef)
	$gzf->translate(undef);
}

sub html_oneshot ($$;$) {
	my ($ctx, $code, $sref) = @_;
	$ctx->{base_url} = base_url($ctx);
	bless $ctx, __PACKAGE__;
	my @x;
	my $h = [ 'Content-Type' => 'text/html; charset=UTF-8',
		'Content-Length' => undef ];
	if (my $gzf = gzf_maybe($h, $ctx->{env})) {
		$gzf->zmore(html_top($ctx));
		$gzf->zmore($$sref) if $sref;
		$x[0] = $gzf->zflush(_html_end($ctx));
		$h->[3] = length($x[0]);
	} else {
		@x = (html_top($ctx), $sref ? $$sref : (), _html_end($ctx));
		$h->[3] += bytes::length($_) for @x;
	}
	[ $code, $h, \@x ]
}

1;
