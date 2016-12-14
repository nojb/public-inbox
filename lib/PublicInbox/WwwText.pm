# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

package PublicInbox::WwwText;
use strict;
use warnings;
use PublicInbox::Linkify;
use PublicInbox::WwwStream;
use PublicInbox::Hval qw(ascii_html);
our $QP_URL = 'https://xapian.org/docs/queryparser.html';
our $WIKI_URL = 'https://en.wikipedia.org/wiki';

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
	if (!_default_text($ctx, $key, \$txt)) {
		$code = 404;
		$txt = "404 Not Found ($key)\n";
	}
	if ($raw) {
		return [ $code, [ 'Content-Type', 'text/plain',
				  'Content-Length', bytes::length($txt) ],
			[ $txt ] ]
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
	_do_linkify($txt);
	$ctx->{-title_html} = ascii_html($title);

	my $nslash = ($key =~ tr!/!/!);
	$ctx->{-upfx} = '../../../' . ('../' x $nslash);

	PublicInbox::WwwStream->response($ctx, $code, sub {
		my ($nr, undef) = @_;
		$nr == 1 ? '<pre>'.$txt.'</pre>' : undef
	});
}

sub _do_linkify {
	my $l = PublicInbox::Linkify->new;
	$_[0] = $l->linkify_2(ascii_html($l->linkify_1($_[0])));
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


sub _default_text ($$$) {
	my ($ctx, $key, $txt) = @_;
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
