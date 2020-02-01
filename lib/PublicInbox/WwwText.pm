# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used for displaying help texts and other non-mail content
package PublicInbox::WwwText;
use strict;
use warnings;
use bytes (); # only for bytes::length
use PublicInbox::Linkify;
use PublicInbox::WwwStream;
use PublicInbox::Hval qw(ascii_html);
use URI::Escape qw(uri_escape_utf8);
our $QP_URL = 'https://xapian.org/docs/queryparser.html';
our $WIKI_URL = 'https://en.wikipedia.org/wiki';
my $hl = eval {
	require PublicInbox::HlMod;
	PublicInbox::HlMod->new
};

# /$INBOX/_/text/$KEY/ # KEY may contain slashes
# For now, "help" is the only supported $KEY
sub get_text {
	my ($ctx, $key) = @_;
	my $code = 200;

	$key = 'help' if !defined $key; # this 302s to _/text/help/

	# get the raw text the same way we get mboxrds
	my $raw = ($key =~ s!/raw\z!!);
	my $have_tslash = ($key =~ s!/\z!!) if !$raw;

	my $txt = '';
	my $hdr = [ 'Content-Type', 'text/plain', 'Content-Length', undef ];
	if (!_default_text($ctx, $key, $hdr, \$txt)) {
		$code = 404;
		$txt = "404 Not Found ($key)\n";
	}
	if ($raw) {
		$hdr->[3] = bytes::length($txt);
		return [ $code, $hdr, [ $txt ] ]
	}

	# enforce trailing slash for "wget -r" compatibility
	if (!$have_tslash && $code == 200) {
		my $url = $ctx->{-inbox}->base_url($ctx->{env});
		$url .= "_/text/$key/";

		return [ 302, [ 'Content-Type', 'text/plain',
				'Location', $url ],
			[ "Redirecting to $url\n" ] ];
	}

	# Follow git commit message conventions,
	# first line is the Subject/title
	my ($title) = ($txt =~ /\A([^\n]*)/s);
	$ctx->{txt} = \$txt;
	$ctx->{-title_html} = ascii_html($title);
	my $nslash = ($key =~ tr!/!/!);
	$ctx->{-upfx} = '../../../' . ('../' x $nslash);
	PublicInbox::WwwStream->response($ctx, $code, \&_do_linkify);
}

sub _do_linkify {
	my ($nr, $ctx) = @_;
	return unless $nr == 1;
	my $l = PublicInbox::Linkify->new;
	my $txt = delete $ctx->{txt};
	$l->linkify_1($$txt);
	if ($hl) {
		$hl->do_hl_text($txt);
	} else {
		$$txt = ascii_html($$txt);
	}
	'<pre>' . $l->linkify_2($$txt) . '</pre>';
}

sub _srch_prefix ($$) {
	my ($srch, $txt) = @_;
	my $pad = 0;
	my $htxt = '';
	my $help = $srch->help;
	my $i;
	for ($i = 0; $i < @$help; $i += 2) {
		my $pfx = $help->[$i];
		my $n = length($pfx);
		$pad = $n if $n > $pad;
		$htxt .= $pfx . "\0";
		$htxt .= $help->[$i + 1];
		$htxt .= "\f\n";
	}
	$pad += 2;
	my $padding = ' ' x ($pad + 8);
	$htxt =~ s/^/$padding/gms;
	$htxt =~ s/^$padding(\S+)\0/"        $1".
				(' ' x ($pad - length($1)))/egms;
	$htxt =~ s/\f\n/\n/gs;
	$$txt .= $htxt;
	1;
}

sub _colors_help ($$) {
	my ($ctx, $txt) = @_;
	my $ibx = $ctx->{-inbox};
	my $env = $ctx->{env};
	my $base_url = $ibx->base_url($env);
	$$txt .= "color customization for $base_url\n";
	$$txt .= <<EOF;

public-inbox provides a stable set of CSS classes for users to
customize colors for highlighting diffs and code.

Users of browsers such as dillo, Firefox, or some browser
extensions may start by downloading the following sample CSS file
to control the colors they see:

	${base_url}userContent.css

CSS sample
----------
```css
EOF
	$$txt .= PublicInbox::UserContent::sample($ibx, $env) . "```\n";
}

# git-config section names are quoted in the config file, so escape them
sub dq_escape ($) {
	my ($name) = @_;
	$name =~ s/\\/\\\\/g;
	$name =~ s/"/\\"/g;
	$name;
}

sub URI_PATH () { '^A-Za-z0-9\-\._~/' }

# n.b. this is a perfect candidate for memoization
sub inbox_config ($$$) {
	my ($ctx, $hdr, $txt) = @_;
	my $ibx = $ctx->{-inbox};
	push @$hdr, 'Content-Disposition', 'inline; filename=inbox.config';
	my $name = dq_escape($ibx->{name});
	$$txt .= <<EOS;
; example public-inbox config snippet for "$name"
; see public-inbox-config(5) manpage for more details:
; https://public-inbox.org/public-inbox-config.html
[publicinbox "$name"]
	inboxdir = /path/to/top-level-inbox
	; note: public-inbox before v1.2.0 used "mainrepo"
	; instead of "inboxdir", both remain supported after 1.2
	mainrepo = /path/to/top-level-inbox
	url = https://example.com/$name/
	url = http://example.onion/$name/
EOS
	for my $k (qw(address listid infourl)) {
		defined(my $v = $ibx->{$k}) or next;
		$$txt .= "\t$k = $_\n" for @$v;
	}

	for my $k (qw(filter newsgroup obfuscate replyto watchheader)) {
		defined(my $v = $ibx->{$k}) or next;
		$$txt .= "\t$k = $v\n";
	}
	$$txt .= "\tnntpmirror = $_\n" for (@{$ibx->nntp_url});

	# note: this doesn't preserve cgitrc layout, since we parse cgitrc
	# and drop the original structure
	if (defined(my $cr = $ibx->{coderepo})) {
		$$txt .= "\tcoderepo = $_\n" for @$cr;

		my $pi_config = $ctx->{www}->{pi_config};
		for my $cr_name (@$cr) {
			my $url = $pi_config->{"coderepo.$cr_name.cgiturl"};
			my $path = "/path/to/$cr_name";
			$cr_name = dq_escape($cr_name);

			$$txt .= qq([coderepo "$cr_name"]\n);
			if (defined($url)) {
				my $cpath = $path;
				if ($path !~ m![a-z0-9_/\.\-]!i) {
					$cpath = dq_escape($cpath);
				}
				$$txt .= qq(\t; git clone $url "$cpath"\n);
			}
			$$txt .= "\tdir = $path\n";
			$$txt .= "\tcgiturl = https://example.com/";
			$$txt .= uri_escape_utf8($cr_name, URI_PATH)."\n";
		}
	}
	1;
}

sub _default_text ($$$$) {
	my ($ctx, $key, $hdr, $txt) = @_;
	return _colors_help($ctx, $txt) if $key eq 'color';
	return inbox_config($ctx, $hdr, $txt) if $key eq 'config';
	return if $key ne 'help'; # TODO more keys?

	my $ibx = $ctx->{-inbox};
	my $base_url = $ibx->base_url($ctx->{env});
	$$txt .= "public-inbox help for $base_url\n";
	$$txt .= <<EOF;

overview
--------

    public-inbox uses Message-ID identifiers in URLs.
    One may look up messages by substituting Message-IDs
    (without the leading '<' or trailing '>') into the URL.
    Forward slash ('/') characters in the Message-IDs
    need to be escaped as "%2F" (without quotes).

    Thus, it is possible to retrieve any message by its
    Message-ID by going to:

	$base_url<Message-ID>/

	(without the '<' or '>')

    Message-IDs are described at:

	$WIKI_URL/Message-ID

EOF

	# n.b. we use the Xapian DB for any regeneratable,
	# order-of-arrival-independent data.
	my $srch = $ibx->search;
	if ($srch) {
		$$txt .= <<EOF;
search
------

    This public-inbox has search functionality provided by Xapian.

    It supports typical AND, OR, NOT, '+', '-' queries present
    in other search engines.

    We also support search prefixes to limit the scope of the
    search to certain fields.

    Prefixes supported in this installation include:

EOF
		_srch_prefix($srch, $txt);

		$$txt .= <<EOF;

    Most prefixes are probabilistic, meaning they support stemming
    and wildcards ('*').  Ranges (such as 'd:') and boolean prefixes
    do not support stemming or wildcards.
    The upstream Xapian query parser documentation fully explains
    the query syntax:

	$QP_URL

message threading
-----------------

    Message threading is enabled for this public-inbox,
    additional endpoints for message threads are available:

    * $base_url<Message-ID>/T/#u

      Loads the thread belonging to the given <Message-ID>
      in flat chronological order.  The "#u" anchor
      focuses the browser on the given <Message-ID>.

    * $base_url<Message-ID>/t/#u

      Loads the thread belonging to the given <Message-ID>
      in threaded order with nesting.  For deep threads,
      this requires a wide display or horizontal scrolling.

    Both of these HTML endpoints are suitable for offline reading
    using the thread overview at the bottom of each page.

    Users of feed readers may follow a particular thread using:

    * $base_url<Message-ID>/t.atom

      Which loads the thread in Atom Syndication Standard
      described at Wikipedia and RFC4287:

	$WIKI_URL/Atom_(standard)
	https://tools.ietf.org/html/rfc4287

      Atom Threading Extensions (RFC4685) is supported:

	https://tools.ietf.org/html/rfc4685

    Finally, the gzipped mbox for a thread is available for
    downloading and importing into your favorite mail client:

    * $base_url<Message-ID>/t.mbox.gz

    We use the mboxrd variant of the mbox format described
    at:

	$WIKI_URL/Mbox

contact
-------

    This help text is maintained by public-inbox developers
    reachable via plain-text email at: meta\@public-inbox.org

EOF
	# TODO: support admin contact info in ~/.public-inbox/config
	}
	1;
}

1;
