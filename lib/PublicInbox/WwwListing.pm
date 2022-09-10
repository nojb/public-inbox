# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Provide an HTTP-accessible listing of inboxes.
# Used by PublicInbox::WWW
package PublicInbox::WwwListing;
use strict;
use v5.10.1;
use PublicInbox::Hval qw(prurl fmt_ts ascii_html);
use PublicInbox::GzipFilter qw(gzf_maybe);
use PublicInbox::ConfigIter;
use PublicInbox::WwwStream;
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::MID qw(mid_escape);

sub ibx_entry {
	my ($ctx, $ibx, $ce) = @_;
	my $desc = ascii_html($ce->{description} //= $ibx->description);
	my $ts = fmt_ts($ce->{-modified} //= $ibx->modified);
	my ($url, $href);
	if (scalar(@{$ibx->{url} // []})) {
		$url = $href = ascii_html(prurl($ctx->{env}, $ibx->{url}));
	} else {
		$href = ascii_html(uri_escape_utf8($ibx->{name})) . '/';
		$url = ascii_html($ibx->{name});
	}
	my $tmp = <<EOM;
* $ts - <a\nhref="$href">$url</a>
  $desc
EOM
	if (defined($url = $ibx->{infourl})) {
		$url = ascii_html(prurl($ctx->{env}, $url));
		$tmp .= qq(  <a\nhref="$url">$url</a>\n);
	}
	push(@{$ctx->{-list}}, (scalar(@_) == 3 ? # $misc in use, already sorted
				$tmp : [ $ce->{-modified}, $tmp ] ));
}

sub list_match_i { # ConfigIter callback
	my ($cfg, $section, $re, $ctx) = @_;
	if (defined($section)) {
		return if $section !~ m!\Apublicinbox\.([^/]+)\z!;
		my $ibx = $cfg->lookup_name($1) or return;
		if (!$ibx->{-hide}->{$ctx->hide_key} &&
					grep(/$re/, @{$ibx->{url} // []})) {
			$ctx->ibx_entry($ibx);
		}
	} else { # undef == "EOF"
		$ctx->{-wcb}->($ctx->psgi_triple);
	}
}

sub url_filter {
	my ($ctx, $key, $default) = @_;
	$key //= 'publicInbox.wwwListing';
	$default //= '404';
	my $v = $ctx->{www}->{pi_cfg}->{lc $key} // $default;
again:
	if ($v eq 'match=domain') {
		my $h = $ctx->{env}->{HTTP_HOST} // $ctx->{env}->{SERVER_NAME};
		$h =~ s/:[0-9]+\z//;
		(qr!\A(?:https?:)?//\Q$h\E(?::[0-9]+)?/!i, "url:$h");
	} elsif ($v eq 'all') {
		(qr/./, undef);
	} elsif ($v eq '404') {
		(undef, undef);
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

sub add_misc_ibx { # MiscSearch->retry_reopen callback
	my ($misc, $ctx, $re, $qs) = @_;
	require PublicInbox::SearchQuery;
	my $q = $ctx->{-sq} = PublicInbox::SearchQuery->new($ctx->{qp});
	my $o = $q->{o};
	my ($asc, $min, $max);
	if ($o < 0) {
		$asc = 1;
		$o = -($o + 1); # so [-1] is the last element, like Perl lists
	}
	my $r = $q->{r};
	my $opt = {
		offset => $o,
		asc => $asc,
		relevance => $r,
		limit => $q->{l}
	};
	$qs .= ' type:inbox';

	delete $ctx->{-list}; # reset if retried
	my $pi_cfg = $ctx->{www}->{pi_cfg};
	my $user_query = $q->{'q'} // '';
	if ($user_query =~ /\S/) {
		$qs = "( $qs ) AND ( $user_query )";
	} else { # special case for ALL
		$ctx->ibx_entry($pi_cfg->ALL // die('BUG: ->ALL expected'), {});
	}
	my $mset = $misc->mset($qs, $opt); # sorts by $MODIFIED (mtime)
	my $hide_key = $ctx->hide_key;

	for my $mi ($mset->items) {
		my $doc = $mi->get_document;
		my ($eidx_key) = PublicInbox::Search::xap_terms('Q', $doc);
		$eidx_key // next;
		my $ibx = $pi_cfg->lookup_eidx_key($eidx_key) // next;
		next if $ibx->{-hide}->{$hide_key};
		grep(/$re/, @{$ibx->{url} // []}) or next;
		$ctx->ibx_entry($ibx, $misc->doc2ibx_cache_ent($doc));
		if ($r) { # for descriptions in search_nav_bot
			my $pct = PublicInbox::Search::get_pct($mi);
			# only when sorting by relevance, ->items is always
			# ordered descending:
			$max //= $pct;
			$min = $pct;
		}
	}
	if ($r) { # for descriptions in search_nav_bot
		$q->{-min_pct} = $min;
		$q->{-max_pct} = $max;
	}
	$ctx->{-mset} = $mset;
	psgi_triple($ctx);
}

sub response {
	my ($class, $ctx) = @_;
	bless $ctx, $class;
	my ($re, $qs) = $ctx->url_filter;
	$re // return $ctx->psgi_triple;
	if (my $ALL = $ctx->{www}->{pi_cfg}->ALL) { # fast path
		if ($ctx->{qp}->{a} && # "search all inboxes"
				$ctx->{qp}->{'q'}) {
			my $u = 'all/?q='.mid_escape($ctx->{qp}->{'q'});
			return [ 302, [ 'Location' => $u,
				qw(Content-Type text/plain) ],
				[ "Redirecting to $u\n" ] ];
		}
		# FIXME: test this in t/
		$ALL->misc->reopen->retry_reopen(\&add_misc_ibx,
						$ctx, $re, $qs);
	} else { # slow path, no [extindex "all"] configured
		my $iter = PublicInbox::ConfigIter->new($ctx->{www}->{pi_cfg},
						\&list_match_i, $re, $ctx);
		sub {
			$ctx->{-wcb} = $_[0]; # HTTP server callback
			$ctx->{env}->{'pi-httpd.async'} ?
					$iter->event_step : $iter->each_section;
		}
	}
}

sub mset_footer ($$) {
	my ($ctx, $mset) = @_;
	# no footer if too few matches
	return '' if $mset->get_matches_estimated == $mset->size;
	require PublicInbox::SearchView;
	PublicInbox::SearchView::search_nav_bot($mset, $ctx->{-sq});
}

sub mset_nav_top {
	my ($ctx, $mset) = @_;
	my $q = $ctx->{-sq};
	my $qh = $q->{'q'} // '';
	if ($qh ne '') {
		utf8::decode($qh);
		$qh = qq[\nvalue="].ascii_html($qh).'"';
	}
	chop(my $rv = <<EOM);
<form action="./"><pre><input name=q type=text$qh/><input
type=submit value="locate inbox"/><input type=submit name=a
value="search all inboxes"/></pre></form><pre>
EOM
	if (defined($q->{'q'})) {
		my $initial_q = $ctx->{-uxs_retried};
		if (defined $initial_q) {
			my $rewritten = $q->{'q'};
			utf8::decode($initial_q);
			utf8::decode($rewritten);
			$initial_q = ascii_html($initial_q);
			$rewritten = ascii_html($rewritten);
			$rv .= " Warning: Initial query:\n <b>$initial_q</b>\n";
			$rv .= " returned no results, used:\n";
			$rv .= " <b>$rewritten</b>\n instead\n\n";
		}
		$rv .= 'Search results ordered by [';
		if ($q->{r}) {
			my $d = $q->qs_html(r => 0);
			$rv .= qq{<a\nhref="?$d">updated</a>|<b>relevance</b>};
		} else {
			my $d = $q->qs_html(r => 1);
			$rv .= qq{<b>updated</b>|<a\nhref="?$d">relevance</a>};
		}
		$rv .= ']';
	}
	$rv .= qq{</pre>};
}

sub psgi_triple {
	my ($ctx) = @_;
	my $h = [ 'Content-Type', 'text/html; charset=UTF-8',
			'Content-Length', undef ];
	my $gzf = gzf_maybe($h, $ctx->{env});
	my $zfh = $gzf->zfh;
	print $zfh '<html><head><title>public-inbox listing</title>',
			$ctx->{www}->style('+/'),
			'</head><body>';
	my $code = 404;
	if (my $list = delete $ctx->{-list}) {
		my $mset = delete $ctx->{-mset};
		$code = 200;
		if ($mset) { # already sorted, so search bar:
			print $zfh mset_nav_top($ctx, $mset);
		} else { # sort config dump by ->modified
			@$list = map { $_->[1] }
				sort { $b->[0] <=> $a->[0] } @$list;
		}
		print $zfh '<pre>', join("\n", @$list); # big
		print $zfh mset_footer($ctx, $mset) if $mset;
	} elsif (my $mset = delete $ctx->{-mset}) {
		print $zfh mset_nav_top($ctx, $mset),
				'<pre>no matching inboxes',
				mset_footer($ctx, $mset);
	} else {
		print $zfh '<pre>no inboxes, yet';
	}
	my $out = $gzf->zflush('</pre><hr><pre>'.
qq(This is a listing of public inboxes, see the `mirror' link of each inbox
for instructions on how to mirror all the data and code on this site.) .
			'</pre></body></html>');
	$h->[3] = length($out);
	[ $code, $h, [ $out ] ];
}

1;
