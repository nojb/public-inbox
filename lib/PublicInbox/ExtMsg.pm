# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used by the web interface to link to messages outside of the our
# public-inboxes.  Mail threads may cross projects/threads; so
# we should ensure users can find more easily find them on other
# sites.
package PublicInbox::ExtMsg;
use strict;
use warnings;
use PublicInbox::Hval qw(ascii_html prurl mid_href);
use PublicInbox::WwwStream qw(html_oneshot);
use PublicInbox::Smsg;
our $MIN_PARTIAL_LEN = 16;

# TODO: user-configurable
our @EXT_URL = map { ascii_html($_) } (
	# leading "//" denotes protocol-relative (http:// or https://)
	'//marc.info/?i=%s',
	'//www.mail-archive.com/search?l=mid&q=%s',
	'nntp://news.gmane.io/%s',
	'https://lists.debian.org/msgid-search/%s',
	'//docs.FreeBSD.org/cgi/mid.cgi?db=mid&id=%s',
	'https://www.w3.org/mid/%s',
	'http://www.postgresql.org/message-id/%s',
	'https://lists.debconf.org/cgi-lurker/keyword.cgi?'.
		'doc-url=/lurker&format=en.html&query=id:%s'
);

sub PARTIAL_MAX () { 100 }

sub search_partial ($$) {
	my ($ibx, $mid) = @_;
	return if length($mid) < $MIN_PARTIAL_LEN;
	my $srch = $ibx->isrch or return;
	my $opt = { limit => PARTIAL_MAX, relevance => -1 };
	my @try = ("m:$mid*");
	my $chop = $mid;
	if ($chop =~ s/(\W+)(\w*)\z//) {
		my ($delim, $word) = ($1, $2);
		if (length($word)) {
			push @try, "m:$chop$delim";
			push @try, "m:$chop$delim*";
		}
		push @try, "m:$chop";
		push @try, "m:$chop*";
	}

	# break out long words individually to search for, because
	# too many messages begin with "Pine.LNX." (or "alpine" or "nycvar")
	if ($mid =~ /\w{9,}/) {
		my @long = ($mid =~ m!(\w{3,})!g);
		push(@try, join(' ', map { "m:$_" } @long));

		# is the last element long enough to not trigger excessive
		# wildcard matches?
		if (length($long[-1]) > 8) {
			$long[-1] .= '*';
			push(@try, join(' ', map { "m:$_" } @long));
		}
	}

	foreach my $m (@try) {
		# If Xapian can't handle the wildcard since it
		# has too many results.  $@ can be
		# Search::Xapian::QueryParserError or even:
		# "something terrible happened at ../Search/Xapian/Enquire.pm"
		my $mset = eval { $srch->mset($m, $opt) } or next;
		my @mids = map {
			$_->{mid}
		} @{$srch->mset_to_smsg($ibx, $mset)};
		return \@mids if scalar(@mids);
	}
}

sub ext_msg_i {
	my ($other, $ctx) = @_;

	return if $other->{name} eq $ctx->{ibx}->{name} || !$other->base_url;

	my $mm = $other->mm or return;

	# try to find the URL with Msgmap to avoid forking
	my $num = $mm->num_for($ctx->{mid});
	if (defined $num) {
		push @{$ctx->{found}}, $other;
	} else {
		# no point in trying the fork fallback if we
		# know Xapian is up-to-date but missing the
		# message in the current repo
		push @{$ctx->{again}}, $other;
	}
}

sub ext_msg_step {
	my ($pi_cfg, $section, $ctx) = @_;
	if (defined($section)) {
		return if $section !~ m!\Apublicinbox\.([^/]+)\z!;
		my $ibx = $pi_cfg->lookup_name($1) or return;
		ext_msg_i($ibx, $ctx);
	} else { # undef == "EOF"
		finalize_exact($ctx);
	}
}

sub ext_msg_ALL ($) {
	my ($ctx) = @_;
	my $ALL = $ctx->{www}->{pi_cfg}->ALL or return;
	my $by_eidx_key = $ctx->{www}->{pi_cfg}->{-by_eidx_key};
	my $cur_key = eval { $ctx->{ibx}->eidx_key } //
			return partial_response($ctx); # $cur->{ibx} == $ALL
	my %seen = ($cur_key => 1);
	my ($id, $prev);
	while (my $x = $ALL->over->next_by_mid($ctx->{mid}, \$id, \$prev)) {
		my $xr3 = $ALL->over->get_xref3($x->{num});
		for my $k (@$xr3) {
			$k =~ s/:[0-9]+:$x->{blob}\z// or next;
			next if $k eq $cur_key;
			my $ibx = $by_eidx_key->{$k} // next;
			$ibx->base_url or next;
			push(@{$ctx->{found}}, $ibx) unless $seen{$k}++;
		}
	}
	return exact($ctx) if $ctx->{found};

	# fall back to partial MID matching
	for my $ibxish ($ctx->{ibx}, $ALL) {
		my $mids = search_partial($ibxish, $ctx->{mid}) or next;
		push @{$ctx->{partial}}, [ $ibxish, $mids ];
		last if ($ctx->{n_partial} += scalar(@$mids)) >= PARTIAL_MAX;
	}
	partial_response($ctx);
}

sub ext_msg {
	my ($ctx) = @_;
	ext_msg_ALL($ctx) // sub {
		$ctx->{-wcb} = $_[0]; # HTTP server write callback

		if ($ctx->{env}->{'pi-httpd.async'}) {
			require PublicInbox::ConfigIter;
			my $iter = PublicInbox::ConfigIter->new(
						$ctx->{www}->{pi_cfg},
						\&ext_msg_step, $ctx);
			$iter->event_step;
		} else {
			$ctx->{www}->{pi_cfg}->each_inbox(\&ext_msg_i, $ctx);
			finalize_exact($ctx);
		}
	};
}

# called via PublicInbox::DS->EventLoop
sub event_step {
	my ($ctx, $sync) = @_;
	# can't find a partial match in current inbox, try the others:
	my $ibx = shift @{$ctx->{again}} or return finalize_partial($ctx);
	my $mids = search_partial($ibx, $ctx->{mid}) or
			return ($sync ? undef : PublicInbox::DS::requeue($ctx));
	$ctx->{n_partial} += scalar(@$mids);
	push @{$ctx->{partial}}, [ $ibx, $mids ];
	$ctx->{n_partial} >= PARTIAL_MAX ? finalize_partial($ctx)
			: ($sync ? undef : PublicInbox::DS::requeue($ctx));
}

sub finalize_exact {
	my ($ctx) = @_;

	return $ctx->{-wcb}->(exact($ctx)) if $ctx->{found};

	# fall back to partial MID matching
	my $mid = $ctx->{mid};
	my $cur = $ctx->{ibx};
	my $mids = search_partial($cur, $mid);
	if ($mids) {
		$ctx->{n_partial} = scalar(@$mids);
		push @{$ctx->{partial}}, [ $cur, $mids ];
	} elsif ($ctx->{again} && length($mid) >= $MIN_PARTIAL_LEN) {
		bless $ctx, __PACKAGE__;
		if ($ctx->{env}->{'pi-httpd.async'}) {
			$ctx->event_step;
			return;
		}

		# synchronous fall-through
		$ctx->event_step while @{$ctx->{again}};
	}
	finalize_partial($ctx);
}

sub _url_pfx ($$) {
	my ($ctx, $u) = @_;
	(index($u, '://') < 0 && index($u, '/') != 0) ?
		"$ctx->{-upfx}../$u" : $u;
}

sub partial_response ($) {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $code = 404;
	my $href = mid_href($mid);
	my $html = ascii_html($mid);
	my $title = "&lt;$html&gt; not found";
	my $s = "<pre>Message-ID &lt;$html&gt;\nnot found\n";
	$ctx->{-upfx} //= '../';
	if (my $n_partial = $ctx->{n_partial}) {
		$code = 300;
		my $es = $n_partial == 1 ? '' : 'es';
		$n_partial .= '+' if ($n_partial == PARTIAL_MAX);
		$s .= "\n$n_partial partial match$es found:\n\n";
		my $cur_name = $ctx->{ibx}->{name};
		foreach my $pair (@{$ctx->{partial}}) {
			my ($ibx, $res) = @$pair;
			my $e = $ibx->{name} eq $cur_name ? $ctx->{env} : undef;
			my $u = _url_pfx($ctx, $ibx->base_url($e) // next);
			foreach my $m (@$res) {
				my $href = mid_href($m);
				my $html = ascii_html($m);
				$s .= qq{<a\nhref="$u$href/">$u$html/</a>\n};
			}
		}
	}
	my $ext = ext_urls($ctx, $mid, $href, $html);
	if ($ext ne '') {
		$s .= $ext;
		$code = 300;
	}
	$ctx->{-html_tip} = $s .= '</pre>';
	$ctx->{-title_html} = $title;
	html_oneshot($ctx, $code);
}

sub finalize_partial ($) { $_[0]->{-wcb}->(partial_response($_[0])) }

sub ext_urls {
	my ($ctx, $mid, $href, $html) = @_;

	# Fall back to external repos if configured
	if (@EXT_URL && index($mid, '@') >= 0) {
		my $env = $ctx->{env};
		my $e = "\nPerhaps try an external site:\n\n";
		foreach my $url (@EXT_URL) {
			my $u = prurl($env, $url);
			my $r = sprintf($u, $href);
			my $t = sprintf($u, $html);
			$e .= qq{<a\nhref="$r">$t</a>\n};
		}
		return $e;
	}
	''
}

sub exact {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $found = $ctx->{found};
	my $href = mid_href($mid);
	my $html = ascii_html($mid);
	my $title = "&lt;$html&gt; found in ";
	my $end = @$found == 1 ? 'another inbox' : 'other inboxes';
	$ctx->{-title_html} = $title . $end;
	$ctx->{-upfx} //= '../';
	my $ext_urls = ext_urls($ctx, $mid, $href, $html);
	my $code = (@$found == 1 && $ext_urls eq '') ? 200 : 300;
	$ctx->{-html_tip} = join('',
			"<pre>Message-ID: &lt;$html&gt;\nfound in $end:\n\n",
				(map {
					my $u = _url_pfx($ctx, $_->base_url);
					qq(<a\nhref="$u$href/">$u$html/</a>\n)
				} @$found),
			$ext_urls, '</pre>');
	html_oneshot($ctx, $code);
}

1;
