# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used for displaying help texts and other non-mail content
package PublicInbox::WwwText;
use strict;
use v5.10.1;
use PublicInbox::Linkify;
use PublicInbox::WwwStream;
use PublicInbox::Hval qw(ascii_html prurl);
use HTTP::Date qw(time2str);
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::GzipFilter qw(gzf_maybe);
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

	$key //= 'help'; # this 302s to _/text/help/

	# get the raw text the same way we get mboxrds
	my $raw = ($key =~ s!/raw\z!!);
	my $have_tslash = ($key =~ s!/\z!!) if !$raw;

	my $txt = '';
	my $hdr = [ 'Content-Type', 'text/plain', 'Content-Length', undef ];
	if (!_default_text($ctx, $key, $hdr, \$txt)) {
		$code = 404;
		$txt = "404 Not Found ($key)\n";
	}
	my $env = $ctx->{env};
	if ($raw) {
		$txt = gzf_maybe($hdr, $env)->zflush($txt) if $code == 200;
		$hdr->[3] = length($txt);
		return [ $code, $hdr, [ $txt ] ]
	}

	# enforce trailing slash for "wget -r" compatibility
	if (!$have_tslash && $code == 200) {
		my $url = $ctx->{ibx}->base_url($env);
		$url .= "_/text/$key/";

		return [ 302, [ 'Content-Type', 'text/plain',
				'Location', $url ],
			[ "Redirecting to $url\n" ] ];
	}

	# Follow git commit message conventions,
	# first line is the Subject/title
	my ($title) = ($txt =~ /\A([^\n]*)/s);
	$ctx->{-title_html} = ascii_html($title);
	my $nslash = ($key =~ tr!/!/!);
	$ctx->{-upfx} = '../../../' . ('../' x $nslash);
	my $l = PublicInbox::Linkify->new;
	$l->linkify_1($txt);
	if ($hl) {
		$hl->do_hl_text(\$txt);
	} else {
		$txt = ascii_html($txt);
	}
	$txt = '<pre>' . $l->linkify_2($txt) . '</pre>';
	$txt =~ s!\bPOP3\b!<a\nid=pop3>POP3</a>!;
	$txt =~ s!\b(Newsgroups?)\b!<a\nid=nntp>$1</a>!;
	$txt =~ s!\bIMAP\b!<a\nid=imap>IMAP</a>!;
	PublicInbox::WwwStream::html_oneshot($ctx, $code, \$txt);
}

sub _srch_prefix ($$) {
	my ($ibx, $txt) = @_;
	my $pad = 0;
	my $htxt = '';
	my $help = $ibx->isrch->help;
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
	my $padding = ' ' x ($pad + 4);
	$htxt =~ s/^/$padding/gms;
	$htxt =~ s/^$padding(\S+)\0/"    $1".(' ' x ($pad - length($1)))/egms;
	$htxt =~ s/\f\n/\n/gs;
	$$txt .= $htxt;
	1;
}

sub _colors_help ($$) {
	my ($ctx, $txt) = @_;
	my $ibx = $ctx->{ibx};
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

sub _coderepo_config ($$) {
	my ($ctx, $txt) = @_;
	my $cr = $ctx->{ibx}->{coderepo} // return;
	# note: this doesn't preserve cgitrc layout, since we parse cgitrc
	# and drop the original structure
	$$txt .= "\tcoderepo = $_\n" for @$cr;
	$$txt .= <<'EOF';

; `coderepo' entries allows blob reconstruction via patch emails if
; the inbox is indexed with Xapian.  `@@ <from-range> <to-range> @@'
; line number ranges in `[PATCH]' emails link to /$INBOX_NAME/$OID/s/,
; an HTTP endpoint which reconstructs git blobs via git-apply(1).
EOF
	my $pi_cfg = $ctx->{www}->{pi_cfg};
	for my $cr_name (@$cr) {
		my $urls = $pi_cfg->get_all("coderepo.$cr_name.cgiturl");
		my $path = "/path/to/$cr_name";
		$cr_name = dq_escape($cr_name);

		$$txt .= qq([coderepo "$cr_name"]\n);
		if ($urls && scalar(@$urls)) {
			$$txt .= "\t; ";
			$$txt .= join(" ||\n\t;\t", map {;
				my $dst = $path;
				if ($path !~ m![a-z0-9_/\.\-]!i) {
					$dst = '"'.dq_escape($dst).'"';
				}
				qq(git clone $_ $dst);
			} @$urls);
			$$txt .= "\n";
		}
		$$txt .= "\tdir = $path\n";
		$$txt .= "\tcgiturl = https://example.com/";
		$$txt .= uri_escape_utf8($cr_name, '^A-Za-z0-9\-\._~/')."\n";
	}
}

# n.b. this is a perfect candidate for memoization
sub inbox_config ($$$) {
	my ($ctx, $hdr, $txt) = @_;
	my $ibx = $ctx->{ibx};
	push @$hdr, 'Content-Disposition', 'inline; filename=inbox.config';
	my $t = eval { $ibx->mm->created_at };
	push(@$hdr, 'Last-Modified', time2str($t)) if $t;
	my $name = dq_escape($ibx->{name});
	my $inboxdir = '/path/to/top-level-inbox';
	my $base_url = $ibx->base_url($ctx->{env});
	$$txt .= <<EOS;
; Example public-inbox config snippet for a mirror of
; $base_url
; See public-inbox-config(5) manpage for more details:
; https://public-inbox.org/public-inbox-config.html
[publicinbox "$name"]
	inboxdir = $inboxdir
	; note: public-inbox before v1.2.0 used `mainrepo' instead of
	; `inboxdir', both remain supported after 1.2
	mainrepo = $inboxdir
	url = https://example.com/$name/
	url = http://example.onion/$name/
EOS
	for my $k (qw(address listid infourl watchheader)) {
		defined(my $v = $ibx->{$k}) or next;
		$$txt .= "\t$k = $_\n" for @$v;
	}
	if (my $altid = $ibx->{altid}) {
		my $altid_map = $ibx->altid_map;
		$$txt .= <<EOF;
	; altid DBs may be used to provide numeric article ID lookup from
	; old, pre-existing sources.  You can recreate them via curl(1),
	; gzip(1), and sqlite3(1) as documented:
EOF
		for (sort keys %$altid_map) {
			$$txt .= "\t;\tcurl -d '' $base_url$_.sql.gz | \\\n" .
				"\t;\tgzip -dc | \\\n" .
				"\t;\tsqlite3 $inboxdir/$_.sqlite3\n";
			$$txt .= "\taltid = serial:$_:file=$_.sqlite3\n";
		}
	}

	for my $k (qw(filter newsgroup obfuscate replyto)) {
		defined(my $v = $ibx->{$k}) or next;
		$$txt .= "\t$k = $v\n";
	}
	$$txt .= "\timapmirror = $_\n" for (@{$ibx->imap_url($ctx)});
	$$txt .= "\tnntpmirror = $_\n" for (@{$ibx->nntp_url($ctx)});
	_coderepo_config($ctx, $txt);
	1;
}

# n.b. this is a perfect candidate for memoization
sub extindex_config ($$$) {
	my ($ctx, $hdr, $txt) = @_;
	my $ibx = $ctx->{ibx};
	push @$hdr, 'Content-Disposition', 'inline; filename=extindex.config';
	my $name = dq_escape($ibx->{name});
	my $base_url = $ibx->base_url($ctx->{env});
	$$txt .= <<EOS;
; Example public-inbox config snippet for the external index (extindex) at:
; $base_url
; See public-inbox-config(5)manpage for more details:
; https://public-inbox.org/public-inbox-config.html
[extindex "$name"]
	topdir = /path/to/extindex-topdir
	url = https://example.com/$name/
	url = http://example.onion/$name/
EOS
	for my $k (qw(infourl)) {
		defined(my $v = $ibx->{$k}) or next;
		$$txt .= "\t$k = $v\n";
	}
	_coderepo_config($ctx, $txt);
	1;
}

sub coderepos_raw ($$) {
	my ($ctx, $top_url) = @_;
	my $cr = $ctx->{ibx}->{coderepo} // return ();
	my $cfg = $ctx->{www}->{pi_cfg};
	my @ret = ('Code repositories for project(s) associated with this '.
		$ctx->{ibx}->thing_type . "\n");
	for my $cr_name (@$cr) {
		my $urls = $cfg->get_all("coderepo.$cr_name.cgiturl");
		if ($urls) {
			for (@$urls) {
				my $u = m!\A(?:[a-z\+]+:)?//!i ? $_ :
					$top_url.$_;
				$ret[0] .= "\n\t" . prurl($ctx->{env}, $u);
			}
		} else {
			$ret[0] .= qq[\n\t$cr_name.git (no URL configured)];
		}
	}
	@ret; # may be empty, this sub is called as an arg for join()
}

sub _add_non_http_urls ($$) {
	my ($ctx, $txt) = @_;
	$ctx->{ibx}->can('nntp_url') or return; # TODO extindex can have IMAP
	my $urls = $ctx->{ibx}->imap_url($ctx);
	if (@$urls) {
		$urls = join("\n  ", @$urls);
		$urls =~ s!://([^/@]+)/!://;AUTH=ANONYMOUS\@$1/!sg;
		$$txt .= <<EOM

IMAP subfolder(s) are available under:
  $urls
  # each subfolder (starting with `0') holds 50K messages at most
EOM
	}
	$urls = $ctx->{ibx}->nntp_url($ctx);
	if (@$urls) {
		$$txt .= @$urls == 1 ? "\nNewsgroup" : "\nNewsgroups are";
		$$txt .= ' available over NNTP:';
		$$txt .= "\n  " . join("\n  ", @$urls) . "\n";
	}
	$urls = $ctx->{ibx}->pop3_url($ctx);
	if (@$urls) {
		$urls = join("\n  ", @$urls);
		$$txt .= <<EOM;

POP3 access is available:
  $urls

The POP3 password is: anonymous
The POP3 username is: \$(uuidgen)\@$ctx->{ibx}->{newsgroup}
where \$(uuidgen) in the output of the `uuidgen' command on your system.
The UUID in the username functions as a private cookie (don't share it).
Idle accounts will expire periodically.
EOM
	}
}

sub _add_onion_note ($) {
	my ($txt) = @_;
	$$txt =~ m!\b[^:]+://\w+\.onion/!i and $$txt .= <<EOM

note: .onion URLs require Tor: https://www.torproject.org/

EOM
}

sub _mirror_help ($$) {
	my ($ctx, $txt) = @_;
	my $ibx = $ctx->{ibx};
	my $base_url = $ibx->base_url($ctx->{env});
	chop $base_url; # no trailing slash for "git clone"
	my $dir = (split(m!/!, $base_url))[-1];
	my %seen = ($base_url => 1);
	my $top_url = $base_url;
	$top_url =~ s!/[^/]+\z!/!;
	$$txt .= "public-inbox mirroring instructions\n\n";
	if ($ibx->can('cloneurl')) { # PublicInbox::Inbox
		$$txt .=
		  "This public inbox may be cloned and mirrored by anyone:\n";
		my @urls;
		my $max = $ibx->max_git_epoch;
		# TODO: some of these URLs may be too long and we may need to
		# do something like code_footer() above, but these are local
		# admin-defined
		if (defined($max)) { # v2
			for my $i (0..$max) {
				# old epochs my be deleted:
				-d "$ibx->{inboxdir}/git/$i.git" or next;
				my $url = "$base_url/$i";
				$seen{$url} = 1;
				push @urls, "$url $dir/git/$i.git";
			}
			my $nr = scalar(@urls);
			if ($nr > 1) {
				chomp($$txt .= <<EOM);

  # this inbox consists of $nr epochs: (no need to clone all of them)
EOM
				$urls[0] .= " # oldest";
				$urls[-1] .= " # newest";
			}
		} else { # v1
			push @urls, $base_url;
		}
		# FIXME: epoch splits can be different in other repositories,
		# use the "cloneurl" file as-is for now:
		for my $u (@{$ibx->cloneurl}) {
			next if $seen{$u}++;
			push @urls, $u;
		}
		$$txt .= "\n";
		$$txt .= join('', map { "  git clone --mirror $_\n" } @urls);
		my $addrs = $ibx->{address} // 'inbox@example.com';
		my $ng = $ibx->{newsgroup} // '';
		substr($ng, 0, 0, ' --ng ') if $ng;
		$addrs = join(' ', @$addrs) if ref($addrs) eq 'ARRAY';
		my $v = defined $max ? '-V2' : '-V1';
		$$txt .= <<EOF;

  # If you have public-inbox 1.1+ installed, you may
  # initialize and index your mirror using the following commands:
  public-inbox-init $v$ng \\
    $ibx->{name} ./$dir $base_url \\
    $addrs
  public-inbox-index ./$dir
EOF
	} else { # PublicInbox::ExtSearch
		$$txt .= <<EOM;
This is an external index which is an amalgamation of several public inboxes.
Each public inbox needs to be mirrored individually.
EOM
		my $v = $ctx->{www}->{pi_cfg}->{lc('publicInbox.wwwListing')};
		if (($v // '') =~ /\A(?:all|match=domain)\z/) {
			$$txt .= <<EOM;
A list of them is available at $top_url
EOM
		}
	}
	my $cfg_link = "$base_url/_/text/config/raw";
	$$txt .= <<EOF;

Example config snippet for mirrors: $cfg_link
EOF
	_add_non_http_urls($ctx, $txt);
	_add_onion_note($txt);

	my $code_url = prurl($ctx->{env}, $PublicInbox::WwwStream::CODE_URL);
	$$txt .= join("\n\n",
		coderepos_raw($ctx, $top_url), # may be empty
		"AGPL code for this site:\n  git clone $code_url");
	1;
}

sub _default_text ($$$$) {
	my ($ctx, $key, $hdr, $txt) = @_;
	if ($key eq 'mirror') {
		return _mirror_help($ctx, $txt);
	} elsif ($key eq 'color') {
		return _colors_help($ctx, $txt);
	} elsif ($key eq 'config') {
		return $ctx->{ibx}->can('cloneurl') ?
			inbox_config($ctx, $hdr, $txt) :
			extindex_config($ctx, $hdr, $txt);
	}
	return if $key ne 'help'; # TODO more keys?

	my $ibx = $ctx->{ibx};
	my $base_url = $ibx->base_url($ctx->{env});
	$$txt .= <<EOF;
public-inbox help for $base_url

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
	if ($ibx->isrch) {
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
		_srch_prefix($ibx, $txt);
		$$txt .= <<EOF;

  Most prefixes are probabilistic, meaning they support stemming
  and wildcards ('*').  Ranges (such as 'd:') and boolean prefixes
  do not support stemming or wildcards.
  The upstream Xapian query parser documentation fully explains
  the query syntax:

    $QP_URL

EOF
	} # $srch
	if ($ibx->over) {
		$$txt .= <<EOF;
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

  The gzipped mbox for a thread is available for downloading and
  importing into your favorite mail client:

  * $base_url<Message-ID>/t.mbox.gz

    We use the mboxrd variant of the mbox format described at:

    $WIKI_URL/Mbox

  Users of feed readers may follow a particular thread using:

  * $base_url<Message-ID>/t.atom

    Which loads the thread in Atom Syndication Standard
    described at Wikipedia and RFC4287:

    $WIKI_URL/Atom_(standard)
    https://tools.ietf.org/html/rfc4287

    Atom Threading Extensions (RFC4685) are supported:

    https://tools.ietf.org/html/rfc4685

EOF
	} # $over

	_add_non_http_urls($ctx, \(my $note = ''));
	$note and $note =~ s/^/  /gms and $$txt .= <<EOF;
additional protocols
--------------------
$note
EOF
	$$txt .= <<EOF;
contact
-------

  This help text is maintained by public-inbox developers
  reachable via plain-text email at: meta\@public-inbox.org
  Their inbox is archived at: https://public-inbox.org/meta/
EOF
	# TODO: support admin contact info in ~/.public-inbox/config
	1;
}

1;
