# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Displays search results for the web interface
package PublicInbox::SearchView;
use strict;
use warnings;
use PublicInbox::SearchMsg;
use PublicInbox::Hval;
use PublicInbox::View;
use PublicInbox::MID qw(mid2path mid_clean);
use Email::MIME;
require PublicInbox::Git;
our $LIM = 50;

sub sres_top_html {
	my ($ctx) = @_;
	my $q = PublicInbox::SearchQuery->new($ctx->{cgi});
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
	my $res = html_start($q, $ctx) . PublicInbox::Hval::PRE;
	if ($err) {
		$code = 400;
		$res .= err_txt($err) . "</pre><hr /><pre>" . foot($ctx);
	} elsif ($total == 0) {
		$code = 404;
		$res .= "\n\n[No results found]</pre><hr /><pre>".foot($ctx);
	} else {
		my $x = $q->{x};
		return sub { adump($_[0], $mset, $q, $ctx) } if ($x eq 'A');

		$res .= search_nav_top($mset, $q);
		if ($x eq 't') {
			return sub { tdump($_[0], $res, $mset, $q, $ctx) };
		}
		$res .= "\n\n";
		dump_mset(\$res, $mset);
		$res .= search_nav_bot($mset, $q) . "\n\n" . foot($ctx);
	}

	$res .= "</pre></body></html>";
	[$code, ['Content-Type'=>'text/html; charset=UTF-8'], [$res]];
}

sub dump_mset {
	my ($res, $mset) = @_;

	my $total = $mset->get_matches_estimated;
	my $pad = length("$total");
	my $pfx = ' ' x $pad;
	foreach my $m ($mset->items) {
		my $rank = sprintf("%${pad}d", $m->get_rank + 1);
		my $pct = $m->get_percent;
		my $smsg = PublicInbox::SearchMsg->load_doc($m->get_document);
		my $s = PublicInbox::Hval->new_oneline($smsg->subject);
		my $f = $smsg->from_name;
		$f = PublicInbox::Hval->new_oneline($f)->as_html;
		my $ts = PublicInbox::View::fmt_ts($smsg->ts);
		my $mid = PublicInbox::Hval->new_msgid($smsg->mid)->as_href;
		$$res .= qq{$rank. <b><a\nhref="$mid/">}.
			$s->as_html . "</a></b>\n";
		$$res .= "$pfx  - by $f @ $ts UTC [$pct%]\n\n";
	}
}

sub err_txt {
	my ($err) = @_;
	my $u = 'http://xapian.org/docs/queryparser.html';
	$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
	$err = PublicInbox::Hval->new_oneline($err)->as_html;
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
		$rv .= qq{<b>summary</b>|};
		$rv .= qq{<a\nhref="?$t">threaded</a>}
	} elsif ($q->{x} eq 't') {
		my $s = $q->qs_html(x => '');
		$rv .= qq{<a\nhref="?$s">summary</a>|};
		$rv .= qq{<b>threaded</b>};
	}
	my $A = $q->qs_html(x => 'A', r => undef);
	$rv .= qq{|<a\nhref="?$A">Atom</a>};
	$rv .= ']';
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
		$rv .= qq{, <a\nhref="?$qs">next</a>}
	}
	if ($o > 0) {
		$rv .= $n < $total ? '/' : ',      ';
		my $p = $o - $LIM;
		my $qs = $q->qs_html(o => ($p > 0 ? $p : 0));
		$rv .= qq{<a\nhref="?$qs">prev</a>};
	}
	$rv;
}

sub tdump {
	my ($cb, $res, $mset, $q, $ctx) = @_;
	my $fh = $cb->([200, ['Content-Type'=>'text/html; charset=UTF-8']]);
	$fh->write($res);
	my %pct;
	my @m = map {
		my $i = $_;
		my $m = PublicInbox::SearchMsg->load_doc($i->get_document);
		$pct{$m->mid} = $i->get_percent;
		$m = $m->mini_mime;
		$m;
	} ($mset->items);

	require PublicInbox::Thread;
	my $th = PublicInbox::Thread->new(@m);
	{
		no warnings 'once';
		$Mail::Thread::nosubject = 0;
	}
	$th->thread;
	if ($q->{r}) {
		$th->order(sub {
			sort { (eval { $pct{$b->topmost->messageid} } || 0)
					<=>
				(eval { $pct{$a->topmost->messageid} } || 0)
			} @_;
		});
	} else {
		no warnings 'once';
		$th->order(*PublicInbox::View::rsort_ts);
	}

	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	my $state = { ctx => $ctx, anchor_idx => 0, pct => \%pct };
	$ctx->{searchview} = 1;
	tdump_ent($fh, $git, $state, $_, 0) for $th->rootset;
	Email::Address->purge_cache;

	$fh->write(search_nav_bot($mset, $q). "\n\n" .
			foot($ctx). '</pre></body></html>');

	$fh->close;
}

sub tdump_ent {
	my ($fh, $git, $state, $node, $level) = @_;
	return unless $node;
	my $mime = $node->message;

	if ($mime) {
		# lazy load the full message from mini_mime:
		my $mid = $mime->header('Message-ID');
		$mime = eval {
			my $path = mid2path(mid_clean($mid));
			Email::MIME->new($git->cat_file('HEAD:'.$path));
		};
	}
	if ($mime) {
		PublicInbox::View::index_entry($fh, $mime, $level, $state);
	} else {
		my $mid = $node->messageid;
		$fh->write(PublicInbox::View::ghost_table('', $mid, $level));
	}
	tdump_ent($fh, $git, $state, $node->child, $level + 1);
	tdump_ent($fh, $git, $state, $node->next, $level);
}

sub foot {
	my ($ctx) = @_;
	my $foot = $ctx->{footer} || '';
	qq{Back to <a\nhref=".">index</a>.\n$foot};
}

sub html_start {
	my ($q, $ctx) = @_;
	my $query = PublicInbox::Hval->new_oneline($q->{q});

	my $qh = $query->as_html;
	my $A = $q->qs_html(x => 'A', r => undef);
	my $res = "<html><head><title>$qh - search results</title>" .
		qq{<link\nrel=alternate\ntitle="Atom feed"\n} .
		qq!href="?$A"\ntype="application/atom+xml"/></head>! .
		qq{<body><form\naction="">} .
		qq{<input\nname=q\nvalue="$qh"\ntype=text />};

	$res .= qq{<input\ntype=hidden\nname=r />} if $q->{r};
	if (my $x = $q->{x}) {
		my $xh = PublicInbox::Hval->new_oneline($x)->as_html;
		$res .= qq{<input\ntype=hidden\nname=x\nvalue="$xh" />};
	}

	$res .= qq{<input\ntype=submit\nvalue=search /></form>};
}

sub adump {
	my ($cb, $mset, $q, $ctx) = @_;
	my $fh = $cb->([ 200, ['Content-Type' => 'application/atom+xml']]);
	my $git = $ctx->{git_dir} ||= PublicInbox::Git->new($ctx->{git_dir});
	my $feed_opts = PublicInbox::Feed::get_feedopts($ctx);
	my $x = PublicInbox::Hval->new_oneline($q->{q})->as_html;
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
	my ($class, $cgi) = @_;
	my $r = $cgi->param('r');
	bless {
		q => $cgi->param('q'),
		x => $cgi->param('x') || '',
		o => int($cgi->param('o') || 0) || 0,
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

	my $q = PublicInbox::Hval->new($self->{q})->as_href;
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
