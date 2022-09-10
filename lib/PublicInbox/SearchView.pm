# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Displays search results for the web interface
package PublicInbox::SearchView;
use strict;
use v5.10.1;
use List::Util qw(min max);
use URI::Escape qw(uri_unescape);
use PublicInbox::Smsg;
use PublicInbox::Hval qw(ascii_html obfuscate_addrs mid_href fmt_ts);
use PublicInbox::View;
use PublicInbox::WwwAtomStream;
use PublicInbox::WwwStream qw(html_oneshot);
use PublicInbox::SearchThread;
use PublicInbox::SearchQuery;
use PublicInbox::Search qw(get_pct);
my %rmap_inc;

sub mbox_results {
	my ($ctx) = @_;
	my $q = PublicInbox::SearchQuery->new($ctx->{qp});
	if ($ctx->{env}->{'psgi.input'}->read(my $buf, 3)) {
		$q->{t} = 1 if $buf =~ /\Ax=[^0]/;
	}
	require PublicInbox::Mbox;
	$q->{x} eq 'm' ? PublicInbox::Mbox::mbox_all($ctx, $q) :
			sres_top_html($ctx);
}

sub sres_top_html {
	my ($ctx) = @_;
	my $srch = $ctx->{ibx}->isrch or
		return PublicInbox::WWW::need($ctx, 'Search');
	my $q = PublicInbox::SearchQuery->new($ctx->{qp});
	my $x = $q->{x};
	my $o = $q->{o};
	my $asc;
	if ($o < 0) {
		$asc = 1;
		$o = -($o + 1); # so [-1] is the last element, like Perl lists
	}

	my $code = 200;
	# double the limit for expanded views:
	my $opts = {
		limit => $q->{l},
		offset => $o,
		relevance => $q->{r},
		threads => $q->{t},
		asc => $asc,
	};
	my ($mset, $total, $err, $html);
retry:
	eval {
		my $query = $q->{'q'};
		$srch->query_approxidate($ctx->{ibx}->git, $query);
		$mset = $srch->mset($query, $opts);
		$total = $mset->get_matches_estimated;
	};
	$err = $@;
	ctx_prepare($q, $ctx);
	if ($err) {
		$code = 400;
		$html = '<pre>'.err_txt($ctx, $err).'</pre><hr>';
	} elsif ($total == 0) {
		if (defined($ctx->{-uxs_retried})) {
			# undo retry damage:
			$q->{'q'} = $ctx->{-uxs_retried};
		} elsif (index($q->{'q'}, '%') >= 0) {
			$ctx->{-uxs_retried} = $q->{'q'};
			$q->{'q'} = uri_unescape($q->{'q'});
			goto retry;
		}
		$code = 404;
		$html = "<pre>\n[No results found]</pre><hr>";
	} else {
		return adump($_[0], $mset, $q, $ctx) if $x eq 'A';

		$ctx->{-html_tip} = search_nav_top($mset, $q, $ctx);
		return mset_thread($ctx, $mset, $q) if $x eq 't';
		mset_summary($ctx, $mset, $q); # appends to {-html_tip}
		$html = '';
	}
	html_oneshot($ctx, $code);
}

# display non-nested search results similar to what users expect from
# regular WWW search engines:
sub mset_summary {
	my ($ctx, $mset, $q) = @_;

	my $total = $mset->get_matches_estimated;
	my $pad = length("$total");
	my $pfx = ' ' x $pad;
	my $res = \($ctx->{-html_tip});
	my $ibx = $ctx->{ibx};
	my $obfs_ibx = $ibx->{obfuscate} ? $ibx : undef;
	my @nums = @{$ibx->isrch->mset_to_artnums($mset)};
	my %num2msg = map { $_->{num} => $_ } @{$ibx->over->get_all(@nums)};
	my ($min, $max, %seen);

	foreach my $m ($mset->items) {
		my $num = shift @nums;
		my $smsg = delete($num2msg{$num}) // do {
			warn "$m $num expired\n";
			next;
		};
		my $mid = $smsg->{mid};
		next if $seen{$mid}++;
		$mid = mid_href($mid);
		$ctx->{-t_max} //= $smsg->{ts};
		my $rank = sprintf("%${pad}d", $m->get_rank + 1);
		my $pct = get_pct($m);

		# only when sorting by relevance, ->items is always
		# ordered descending:
		$max //= $pct;
		$min = $pct;

		my $s = ascii_html($smsg->{subject});
		my $f = ascii_html(delete $smsg->{from_name});
		if ($obfs_ibx) {
			obfuscate_addrs($obfs_ibx, $s);
			obfuscate_addrs($obfs_ibx, $f);
		}
		my $date = fmt_ts($smsg->{ds});
		$s = '(no subject)' if $s eq '';
		$$res .= qq{$rank. <b><a\nhref="$mid/">}.
			$s . "</a></b>\n";
		$$res .= "$pfx  - by $f @ $date UTC [$pct%]\n\n";
	}
	if ($q->{r}) { # for descriptions in search_nav_bot
		$q->{-min_pct} = $min;
		$q->{-max_pct} = $max;
	}
	$$res .= search_nav_bot($mset, $q);
	undef;
}

# shorten "/full/path/to/Foo/Bar.pm" to "Foo/Bar.pm" so error
# messages don't reveal FS layout info in case people use non-standard
# installation paths
sub path2inc ($) {
	my $full = $_[0];
	if (my $short = $rmap_inc{$full}) {
		return $short;
	} elsif (!scalar(keys %rmap_inc) && -e $full) {
		%rmap_inc = map {; "$INC{$_}" => $_ } keys %INC;
		# fall back to basename as last resort
		$rmap_inc{$full} // (split('/', $full))[-1];
	} else {
		$full;
	}
}

sub err_txt {
	my ($ctx, $err) = @_;
	my $u = $ctx->{ibx}->base_url($ctx->{env}) . '_/text/help/';
	$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
	$err =~ s!(\S+)!path2inc($1)!sge;
	$err = ascii_html($err);
	"\nBad query: <b>$err</b>\n" .
		qq{See <a\nhref="$u">$u</a> for help on using search};
}

sub search_nav_top {
	my ($mset, $q, $ctx) = @_;
	my $m = $q->qs_html(x => 'm', r => undef, t => undef);
	my $rv = qq{<form\nid=d\naction="?$m"\nmethod=post><pre>};
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
		$rv .= qq{<a\nhref="?$d">date</a>|<b>relevance</b>};
	} else {
		my $d = $q->qs_html(r => 1);
		$rv .= qq{<b>date</b>|<a\nhref="?$d">relevance</a>};
	}

	$rv .= ']  view[';

	my $x = $q->{x};
	my $pfx = "\t\t\t";
	if ($x eq 't') {
		my $s = $q->qs_html(x => '');
		$rv .= qq{<a\nhref="?$s">summary</a>|<b>nested</b>};
		$pfx = "thread overview <a\nhref=#t>below</a> | ";
	} else {
		my $t = $q->qs_html(x => 't');
		$rv .= qq{<b>summary</b>|<a\nhref="?$t">nested</a>}
	}
	my $A = $q->qs_html(x => 'A', r => undef);
	$rv .= qq{|<a\nhref="?$A">Atom feed</a>]\n};
	$rv .= <<EOM if $x ne 't' && $q->{t};
*** "t=1" collapses threads in summary, "full threads" requires mbox.gz ***
EOM
	$rv .= <<EOM if $x eq 'm';
*** "x=m" ignored for GET requests, use download buttons below ***
EOM
	if ($ctx->{ibx}->isrch->has_threadid) {
		$rv .= qq{${pfx}download mbox.gz: } .
			# we set name=z w/o using it since it seems required for
			# lynx (but works fine for w3m).
			qq{<input\ntype=submit\nname=z\n} .
				q{value="results only"/>} .
			qq{|<input\ntype=submit\nname=x\n} .
				q{value="full threads"/>};
	} else { # BOFH needs to --reindex
		$rv .= qq{${pfx}download: } .
			qq{<input\ntype=submit\nname=z\nvalue="mbox.gz"/>}
	}
	$rv .= qq{</pre></form><pre>};
}

sub search_nav_bot { # also used by WwwListing for searching extindex miscidx
	my ($mset, $q) = @_;
	my $total = $mset->get_matches_estimated;
	my $l = $q->{l};
	my $rv = '</pre><hr><pre id=t>';
	my $o = $q->{o};
	my $off = $o < 0 ? -($o + 1) : $o;
	my $end = $off + $mset->size;
	my $beg = $off + 1;

	if ($beg <= $end) {
		my $approx = $end == $total ? '' : '~';
		$rv .= "Results $beg-$end of $approx$total";
	} else {
		$rv .= "No more results, only $total";
	}
	my ($next, $join, $prev, $nd, $pd);

	if ($o >= 0) { # sort descending
		my $n = $o + $l;
		if ($n < $total) {
			$next = $q->qs_html(o => $n, l => $l);
			$nd = $q->{r} ? "[&lt;= $q->{-min_pct}%]" : '(older)';
		}
		if ($o > 0) {
			$join = $n < $total ? ' | ' : "\t";
			my $p = $o - $l;
			$prev = $q->qs_html(o => ($p > 0 ? $p : 0));
			$pd = $q->{r} ? "[&gt;= $q->{-max_pct}%]" : '(newer)';
		}
	} else { # o < 0, sort ascending
		my $n = $o - $l;

		if (-$n < $total) {
			$next = $q->qs_html(o => $n, l => $l);
			$nd = $q->{r} ? "[&lt;= $q->{-min_pct}%]" : '(newer)';
		}
		if ($o < -1) {
			$join = -$n < $total ? ' | ' : "\t";
			my $p = $o + $l;
			$prev = $q->qs_html(o => ($p < 0 ? $p : 0));
			$pd = $q->{r} ? "[&gt;= $q->{-max_pct}%]" : '(older)';
		}
	}

	$rv .= qq{  <a\nhref="?$next"\nrel=next>next $nd</a>} if $next;
	$rv .= $join if $join;
	$rv .= qq{<a\nhref="?$prev"\nrel=prev>prev $pd</a>} if $prev;

	my $rev = $q->qs_html(o => $o < 0 ? 0 : -1);
	$rv .= qq{ | <a\nhref="?$rev">reverse</a>} .
		q{ | sort options + mbox downloads } .
		q{<a href=#d>above</a></pre>};
}

sub sort_relevance {
	@{$_[0]} = sort {
		(eval { $b->topmost->{pct} } // 0) <=>
		(eval { $a->topmost->{pct} } // 0)
	} @{$_[0]};
}

sub mset_thread {
	my ($ctx, $mset, $q) = @_;
	my $ibx = $ctx->{ibx};
	my @pct = map { get_pct($_) } $mset->items;
	my $msgs = $ibx->isrch->mset_to_smsg($ibx, $mset);
	my $i = 0;
	$_->{pct} = $pct[$i++] for @$msgs;
	my $r = $q->{r};
	if ($r) { # for descriptions in search_nav_bot
		$q->{-min_pct} = min(@pct);
		$q->{-max_pct} = max(@pct);
	}
	my $rootset = PublicInbox::SearchThread::thread($msgs,
		$r ? \&sort_relevance : \&PublicInbox::View::sort_ds,
		$ctx);
	my $skel = search_nav_bot($mset, $q).
		"<pre>-- links below jump to the message on this page --\n";

	$ctx->{-upfx} = '';
	$ctx->{anchor_idx} = 1;
	$ctx->{cur_level} = 0;
	$ctx->{skel} = \$skel;
	$ctx->{mapping} = {};
	$ctx->{searchview} = 1;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{s_nr} = scalar(@$msgs).'+ results';

	# reduce hash lookups in skel_dump
	$ctx->{-obfs_ibx} = $ibx->{obfuscate} ? $ibx : undef;
	PublicInbox::View::walk_thread($rootset, $ctx,
		\&PublicInbox::View::pre_thread);

	# link $INBOX_DIR/description text to "recent" view around
	# the newest message in this result set:
	$ctx->{-t_max} = max(map { delete $_->{ts} } @$msgs);

	@$msgs = reverse @$msgs if $r;
	$ctx->{msgs} = $msgs;
	PublicInbox::WwwStream::aresponse($ctx, \&mset_thread_i);
}

# callback for PublicInbox::WwwStream::getline
sub mset_thread_i {
	my ($ctx, $eml) = @_;
	print { $ctx->zfh } $ctx->html_top if exists $ctx->{-html_tip};
	$eml and return PublicInbox::View::eml_entry($ctx, $eml);
	my $smsg = shift @{$ctx->{msgs}} or
		print { $ctx->zfh } ${delete($ctx->{skel})};
	$smsg;
}

sub ctx_prepare {
	my ($q, $ctx) = @_;
	my $qh = $q->{'q'};
	utf8::decode($qh);
	$qh = ascii_html($qh);
	$ctx->{-q_value_html} = $qh;
	$ctx->{-atom} = '?'.$q->qs_html(x => 'A', r => undef);
	$ctx->{-title_html} = "$qh - search results";
	my $extra = '';
	$extra .= qq{<input\ntype=hidden\nname=r />} if $q->{r};
	if (my $x = $q->{x}) {
		$x = ascii_html($x);
		$extra .= qq{<input\ntype=hidden\nname=x\nvalue="$x" />};
	}
	$ctx->{-extra_form_html} = $extra;
}

sub adump {
	my ($cb, $mset, $q, $ctx) = @_;
	$ctx->{ids} = $ctx->{ibx}->isrch->mset_to_artnums($mset);
	$ctx->{search_query} = $q; # used by WwwAtomStream::atom_header
	PublicInbox::WwwAtomStream->response($ctx, \&adump_i);
}

# callback for PublicInbox::WwwAtomStream::getline
sub adump_i {
	my ($ctx) = @_;
	while (my $num = shift @{$ctx->{ids}}) {
		my $smsg = eval { $ctx->{ibx}->over->get_art($num) } or next;
		return $smsg;
	}
}

1;
