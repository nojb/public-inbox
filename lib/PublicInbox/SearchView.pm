# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Displays search results for the web interface
package PublicInbox::SearchView;
use strict;
use warnings;
use PublicInbox::SearchMsg;
use PublicInbox::Hval qw/ascii_html/;
use PublicInbox::View;
use PublicInbox::MID qw(mid2path mid_clean mid_mime);
use Email::MIME;
require PublicInbox::Git;
require PublicInbox::Thread;
our $LIM = 50;

sub sres_top_html {
	my ($ctx) = @_;
	my $q = PublicInbox::SearchQuery->new($ctx->{qp});
	my $code = 200;

	# double the limit for expanded views:
	my $opts = {
		limit => $LIM,
		offset => $q->{o},
		mset => 1,
		relevance => $q->{r},
	};
	my ($mset, $total);

	eval {
		$mset = $ctx->{srch}->query($q->{q}, $opts);
		$total = $mset->get_matches_estimated;
	};
	my $err = $@;
	my $res = html_start($q, $ctx) . '<pre>';
	if ($err) {
		$code = 400;
		$res .= err_txt($ctx, $err) . "</pre><hr /><pre>" . foot($ctx);
	} elsif ($total == 0) {
		$code = 404;
		$res .= "\n\n[No results found]</pre><hr /><pre>".foot($ctx);
	} else {
		my $x = $q->{x};
		return sub { adump($_[0], $mset, $q, $ctx) } if ($x eq 'A');

		$res .= search_nav_top($mset, $q) . "\n\n";
		if ($x eq 't') {
			return sub { tdump($_[0], $res, $mset, $q, $ctx) };
		}
		dump_mset(\$res, $mset);
		$res .= '</pre>' . search_nav_bot($mset, $q) .
			"\n\n" . foot($ctx);
	}

	$res .= "</pre></body></html>";
	[$code, ['Content-Type'=>'text/html; charset=UTF-8'], [$res]];
}

# display non-threaded search results similar to what users expect from
# regular WWW search engines:
sub dump_mset {
	my ($res, $mset) = @_;

	my $total = $mset->get_matches_estimated;
	my $pad = length("$total");
	my $pfx = ' ' x $pad;
	foreach my $m ($mset->items) {
		my $rank = sprintf("%${pad}d", $m->get_rank + 1);
		my $pct = $m->get_percent;
		my $smsg = PublicInbox::SearchMsg->load_doc($m->get_document);
		my $s = ascii_html($smsg->subject);
		my $f = ascii_html($smsg->from_name);
		my $ts = PublicInbox::View::fmt_ts($smsg->ts);
		my $mid = PublicInbox::Hval->new_msgid($smsg->mid)->as_href;
		$$res .= qq{$rank. <b><a\nhref="$mid/">}.
			$s . "</a></b>\n";
		$$res .= "$pfx  - by $f @ $ts UTC [$pct%]\n\n";
	}
}

sub err_txt {
	my ($ctx, $err) = @_;
	my $u = '//xapian.org/docs/queryparser.html';
	$u = PublicInbox::Hval::prurl($ctx->{cgi}->{env}, $u);
	$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
	$err = ascii_html($err);
	"\n\nBad query: <b>$err</b>\n" .
		qq{See <a\nhref="$u">$u</a> for Xapian query syntax};
}

sub search_nav_top {
	my ($mset, $q) = @_;

	my $rv = "Search results ordered by [";
	if ($q->{r}) {
		my $d = $q->qs_html(r => 0);
		$rv .= qq{<a\nhref="?$d">date</a>|<b>relevance</b>};
	} else {
		my $d = $q->qs_html(r => 1);
		$rv .= qq{<b>date</b>|<a\nhref="?$d">relevance</a>};
	}

	$rv .= ']  view[';

	my $x = $q->{x};
	if ($x eq '') {
		my $t = $q->qs_html(x => 't');
		$rv .= qq{<b>summary</b>|<a\nhref="?$t">threaded</a>}
	} elsif ($q->{x} eq 't') {
		my $s = $q->qs_html(x => '');
		$rv .= qq{<a\nhref="?$s">summary</a>|<b>threaded</b>};
	}
	my $A = $q->qs_html(x => 'A', r => undef);
	$rv .= qq{|<a\nhref="?$A">Atom feed</a>]};
}

sub search_nav_bot {
	my ($mset, $q) = @_;
	my $total = $mset->get_matches_estimated;
	my $nr = scalar $mset->items;
	my $o = $q->{o};
	my $end = $o + $nr;
	my $beg = $o + 1;
	my $rv = "<hr /><pre>Results $beg-$end of $total";
	my $n = $o + $LIM;

	if ($n < $total) {
		my $qs = $q->qs_html(o => $n);
		$rv .= qq{, <a\nhref="?$qs"\nrel=next>next</a>}
	}
	if ($o > 0) {
		$rv .= $n < $total ? '/' : ',      ';
		my $p = $o - $LIM;
		my $qs = $q->qs_html(o => ($p > 0 ? $p : 0));
		$rv .= qq{<a\nhref="?$qs"\nrel=prev>prev</a>};
	}
	$rv;
}

sub tdump {
	my ($cb, $res, $mset, $q, $ctx) = @_;
	my $fh = $cb->([200, ['Content-Type'=>'text/html; charset=UTF-8']]);
	$fh->write($res .= '</pre>');
	my %pct;
	my @m = map {
		my $i = $_;
		my $m = PublicInbox::SearchMsg->load_doc($i->get_document);
		$pct{$m->mid} = $i->get_percent;
		$m = $m->mini_mime;
		$m;
	} ($mset->items);

	my @rootset;
	my $th = PublicInbox::Thread->new(@m);
	$th->thread;
	if ($q->{r}) { # order by relevance
		$th->order(sub {
			sort { (eval { $pct{$b->topmost->messageid} } || 0)
					<=>
				(eval { $pct{$a->topmost->messageid} } || 0)
			} @_;
		});
	} else { # order by time (default for threaded view)
		$th->order(*PublicInbox::View::sort_ts);
	}
	@rootset = $th->rootset;
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	my $state = {
		ctx => $ctx,
		anchor_idx => 0,
		pct => \%pct,
		cur_level => 0,
		fh => $fh,
	};
	$ctx->{searchview} = 1;
	tdump_ent($git, $state, $_, 0) for @rootset;
	PublicInbox::View::thread_adj_level($state, 0);

	$fh->write(search_nav_bot($mset, $q). "\n\n" .
			foot($ctx). '</pre></body></html>');

	$fh->close;
}

sub tdump_ent {
	my ($git, $state, $node, $level) = @_;
	return unless $node;
	my $mime = $node->message;

	if ($mime) {
		# lazy load the full message from mini_mime:
		my $mid = mid_mime($mime);
		$mime = eval {
			my $path = mid2path(mid_clean($mid));
			Email::MIME->new($git->cat_file('HEAD:'.$path));
		};
	}
	if ($mime) {
		my $end = PublicInbox::View::thread_adj_level($state, $level);
		PublicInbox::View::index_entry($mime, $level, $state);
		$state->{fh}->write($end) if $end;
	} else {
		my $mid = $node->messageid;
		PublicInbox::View::ghost_flush($state, '', $mid, $level);
	}
	tdump_ent($git, $state, $node->child, $level + 1);
	tdump_ent($git, $state, $node->next, $level);
}

sub foot {
	my ($ctx) = @_;
	my $foot = $ctx->{footer} || '';
	qq{Back to <a\nhref=".">index</a>.\n$foot};
}

sub html_start {
	my ($q, $ctx) = @_;
	my $qh = ascii_html($q->{'q'});
	my $A = $q->qs_html(x => 'A', r => undef);
	my $res = '<html><head>' . PublicInbox::Hval::STYLE .
		"<title>$qh - search results</title>" .
		qq{<link\nrel=alternate\ntitle="Atom feed"\n} .
		qq!href="?$A"\ntype="application/atom+xml"/></head>! .
		qq{<body><form\naction="">} .
		qq{<input\nname=q\nvalue="$qh"\ntype=text />};

	$res .= qq{<input\ntype=hidden\nname=r />} if $q->{r};
	if (my $x = $q->{x}) {
		$x = ascii_html($x);
		$res .= qq{<input\ntype=hidden\nname=x\nvalue="$x" />};
	}

	$res .= qq{<input\ntype=submit\nvalue=search /></form>};
}

sub adump {
	my ($cb, $mset, $q, $ctx) = @_;
	my $fh = $cb->([ 200, ['Content-Type' => 'application/atom+xml']]);
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	my $feed_opts = PublicInbox::Feed::get_feedopts($ctx);
	my $x = ascii_html($q->{'q'});
	$x = qq{$x - search results};
	$feed_opts->{atomurl} = $feed_opts->{url} . '?'. $q->qs_html;
	$feed_opts->{url} .= '?'. $q->qs_html(x => undef);
	$x = PublicInbox::Feed::atom_header($feed_opts, $x);
	$fh->write($x. PublicInbox::Feed::feed_updated());

	for ($mset->items) {
		$x = PublicInbox::SearchMsg->load_doc($_->get_document)->mid;
		$x = mid2path($x);
		PublicInbox::Feed::add_to_feed($feed_opts, $fh, $x, $git);
	}
	PublicInbox::Feed::end_feed($fh);
}

package PublicInbox::SearchQuery;
use strict;
use warnings;
use PublicInbox::Hval;

sub new {
	my ($class, $qp) = @_;

	my $r = $qp->{r};
	bless {
		q => $qp->{'q'},
		x => $qp->{x} || '',
		o => (($qp->{o} || '0') =~ /(\d+)/),
		r => (defined $r && $r ne '0'),
	}, $class;
}

sub qs_html {
	my ($self, %over) = @_;

	if (keys %over) {
		my $tmp = bless { %$self }, ref($self);
		foreach my $k (keys %over) {
			$tmp->{$k} = $over{$k};
		}
		$self = $tmp;
	}

	my $q = PublicInbox::Hval->new($self->{'q'})->as_href;
	$q =~ s/%20/+/g; # improve URL readability
	my $qs = "q=$q";

	if (my $o = $self->{o}) { # ignore o == 0
		$qs .= "&amp;o=$o";
	}
	if (my $r = $self->{r}) {
		$qs .= "&amp;r";
	}
	if (my $x = $self->{x}) {
		$qs .= "&amp;x=$x" if ($x eq 't' || $x eq 'A');
	}
	$qs;
}

1;
