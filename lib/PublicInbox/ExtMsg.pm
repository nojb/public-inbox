# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used by the web interface to link to messages outside of the our
# public-inboxes.  Mail threads may cross projects/threads; so
# we should ensure users can find more easily find them on other
# sites.
package PublicInbox::ExtMsg;
use strict;
use warnings;
use PublicInbox::Hval;
use PublicInbox::MID qw/mid2path/;
use PublicInbox::WwwStream;

# TODO: user-configurable
our @EXT_URL = (
	'http://mid.gmane.org/%s',
	'https://lists.debian.org/msgid-search/%s',
	# leading "//" denotes protocol-relative (http:// or https://)
	'//mid.mail-archive.com/%s',
	'//marc.info/?i=%s',
);

sub ext_msg {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $cur = $ctx->{-inbox};
	my $mid = $ctx->{mid};
	my $env = $ctx->{env};

	eval { require PublicInbox::Search };
	my $have_xap = $@ ? 0 : 1;
	my (@nox, @ibx, @found);

	$pi_config->each_inbox(sub {
		my ($other) = @_;
		return if $other->{name} eq $cur->{name} || !$other->base_url;

		my $s = $other->search;
		if (!$s) {
			push @nox, $other;
			return;
		}

		# try to find the URL with Xapian to avoid forking
		my $doc_id = eval { $s->find_unique_doc_id('mid', $mid) };
		if ($@) {
			# xapian not configured properly for this repo
			push @nox, $other;
			return;
		}

		# maybe we found it!
		if (defined $doc_id) {
			push @found, $other;
		} else {
			# no point in trying the fork fallback if we
			# know Xapian is up-to-date but missing the
			# message in the current repo
			push @ibx, $other;
		}
	});

	return exact($ctx, \@found, $mid) if @found;

	# Xapian not installed or configured for some repos,
	# do a full MID check (this is expensive...):
	if (@nox) {
		my $path = mid2path($mid);
		foreach my $other (@nox) {
			my (undef, $type, undef) = $other->path_check($path);

			if ($type && $type eq 'blob') {
				push @found, $other;
			}
		}
	}
	return exact($ctx, \@found, $mid) if @found;

	# fall back to partial MID matching
	my $n_partial = 0;
	my @partial;

	eval { require PublicInbox::Msgmap };
	my $have_mm = $@ ? 0 : 1;
	if ($have_mm) {
		my $tmp_mid = $mid;
again:
		unshift @ibx, $cur;
		foreach my $ibx (@ibx) {
			my $mm = $ibx->mm or next;
			if (my $res = $mm->mid_prefixes($tmp_mid)) {
				$n_partial += scalar(@$res);
				push @partial, [ $ibx, $res ];
			}
		}
		# fixup common errors:
		if (!$n_partial && $tmp_mid =~ s,/[tTf],,) {
			goto again;
		}
	}

	my $code = 404;
	my $h = PublicInbox::Hval->new_msgid($mid);
	my $href = $h->as_href;
	my $html = $h->as_html;
	my $title = "Message-ID &lt;$html&gt; not found";
	my $s = "<html><head><title>$title</title>" .
		"</head><body><pre><b>$title</b>\n";

	if ($n_partial) {
		$code = 300;
		my $es = $n_partial == 1 ? '' : 'es';
		$s.= "\n$n_partial partial match$es found:\n\n";
		foreach my $pair (@partial) {
			my ($ibx, $res) = @$pair;
			my $u = $ibx->base_url or next;
			foreach my $m (@$res) {
				my $p = PublicInbox::Hval->new_msgid($m);
				my $r = $p->as_href;
				my $t = $p->as_html;
				$s .= qq{<a\nhref="$u$r/">$u$t/</a>\n};
			}
		}
	}

	# Fall back to external repos if configured
	if (@EXT_URL && index($mid, '@') >= 0) {
		$code = 300;
		$s .= "\nPerhaps try an external site:\n\n";
		foreach my $url (@EXT_URL) {
			my $u = PublicInbox::Hval::prurl($env, $url);
			my $r = sprintf($u, $href);
			my $t = sprintf($u, $html);
			$s .= qq{<a\nhref="$r">$t</a>\n};
		}
	}
	$s .= '</pre></body></html>';

	[$code, ['Content-Type'=>'text/html; charset=UTF-8'], [$s]];
}

sub ext_urls {
	my ($ctx, $mid, $href, $html) = @_;

	# Fall back to external repos if configured
	if (@EXT_URL && index($mid, '@') >= 0) {
		my $env = $ctx->{env};
		my $e = "\nPerhaps try an external site:\n\n";
		foreach my $url (@EXT_URL) {
			my $u = PublicInbox::Hval::prurl($env, $url);
			my $r = sprintf($u, $href);
			my $t = sprintf($u, $html);
			$e .= qq{<a\nhref="$r">$t</a>\n};
		}
		return $e;
	}
	''
}

sub exact {
	my ($ctx, $found, $mid) = @_;
	my $h = PublicInbox::Hval->new_msgid($mid);
	my $href = $h->as_href;
	my $html = $h->as_html;
	my $title = "&lt;$html&gt; found in ";
	my $end = @$found == 1 ? 'another inbox' : 'other inboxes';
	$ctx->{-title_html} = $title . $end;
	$ctx->{-upfx} = '../';
	my $ext_urls = ext_urls($ctx, $mid, $href, $html);
	my $code = (@$found == 1 && $ext_urls eq '') ? 200 : 300;
	$ctx->{-html_tip} = join('',
			"<pre>Message-ID: &lt;$html&gt;\nfound in $end:\n\n",
				(map {
					my $u = $_->base_url;
					qq(<a\nhref="$u$href/">$u$html/</a>\n)
				} @$found),
			$ext_urls, '</pre>');
	PublicInbox::WwwStream->response($ctx, $code);
}

1;
