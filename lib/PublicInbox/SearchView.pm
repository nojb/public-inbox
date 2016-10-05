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
use PublicInbox::MID qw(mid2path mid_mime mid_clean mid_escape);
use Email::MIME;
require PublicInbox::Git;
require PublicInbox::SearchThread;
our $LIM = 50;

sub noop {}

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
		$mset = $ctx->{srch}->query($q->{'q'}, $opts);
		$total = $mset->get_matches_estimated;
	};
	my $err = $@;
	ctx_prepare($q, $ctx);
	my $cb;
	if ($err) {
		$code = 400;
		$ctx->{-html_tip} = '<pre>'.err_txt($ctx, $err).'</pre><hr>';
		$cb = *noop;
	} elsif ($total == 0) {
		$code = 404;
		$ctx->{-html_tip} = "<pre>\n[No results found]</pre><hr>";
		$cb = *noop;
	} else {
		my $x = $q->{x};
		return sub { adump($_[0], $mset, $q, $ctx) } if ($x eq 'A');

		$ctx->{-html_tip} = search_nav_top($mset, $q) . "\n\n";
		if ($x eq 't') {
			$cb = mset_thread($ctx, $mset, $q);
		} else {
			$cb = mset_summary($ctx, $mset, $q);
		}
	}
	PublicInbox::WwwStream->response($ctx, $code, $cb);
}

# display non-threaded search results similar to what users expect from
# regular WWW search engines:
sub mset_summary {
	my ($ctx, $mset, $q) = @_;

	my $total = $mset->get_matches_estimated;
	my $pad = length("$total");
	my $pfx = ' ' x $pad;
	my $res = \($ctx->{-html_tip});
	foreach my $m ($mset->items) {
		my $rank = sprintf("%${pad}d", $m->get_rank + 1);
		my $pct = $m->get_percent;
		my $smsg = PublicInbox::SearchMsg->load_doc($m->get_document);
		my $s = ascii_html($smsg->subject);
		my $f = ascii_html($smsg->from_name);
		my $ts = PublicInbox::View::fmt_ts($smsg->ts);
		my $mid = PublicInbox::Hval->new_msgid($smsg->mid)->{href};
		$$res .= qq{$rank. <b><a\nhref="$mid/">}.
			$s . "</a></b>\n";
		$$res .= "$pfx  - by $f @ $ts UTC [$pct%]\n\n";
	}
	$$res .= search_nav_bot($mset, $q);
	*noop;
}

sub err_txt {
	my ($ctx, $err) = @_;
	my $u = $ctx->{-inbox}->base_url($ctx->{env}) . '_/text/help/';
	$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
	$err = ascii_html($err);
	"\nBad query: <b>$err</b>\n" .
		qq{See <a\nhref="$u">$u</a> for help on using search};
}

sub search_nav_top {
	my ($mset, $q) = @_;

	my $rv = "<pre>Search results ordered by [";
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
	my $rv = "</pre><hr><pre>Results $beg-$end of $total";
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
	$rv .= '</pre>';
}

sub mset_thread {
	my ($ctx, $mset, $q) = @_;
	my %pct;
	my @m = map {
		my $i = $_;
		my $m = PublicInbox::SearchMsg->load_doc($i->get_document);
		$pct{$m->mid} = $i->get_percent;
		$m = $m->mini_mime;
		$m;
	} ($mset->items);

	my $th = PublicInbox::SearchThread->new(\@m);
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
	my $skel = search_nav_bot($mset, $q). "<pre>";
	my $inbox = $ctx->{-inbox};
	$ctx->{-upfx} = '';
	$ctx->{anchor_idx} = 1;
	$ctx->{cur_level} = 0;
	$ctx->{dst} = \$skel;
	$ctx->{mapping} = {};
	$ctx->{pct} = \%pct;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{seen} = {};
	$ctx->{s_nr} = scalar(@m).'+ results';

	PublicInbox::View::walk_thread($th, $ctx,
		*PublicInbox::View::pre_thread);

	my $msgs = \@m;
	my $mime;
	sub {
		return unless $msgs;
		while ($mime = shift @$msgs) {
			my $mid = mid_clean(mid_mime($mime));
			$mime = $inbox->msg_by_mid($mid) and last;
		}
		if ($mime) {
			$mime = Email::MIME->new($mime);
			return PublicInbox::View::index_entry($mime, $ctx,
				scalar @$msgs);
		}
		$msgs = undef;
		$skel .= "\n</pre>";
	};
}

sub ctx_prepare {
	my ($q, $ctx) = @_;
	my $qh = ascii_html($q->{'q'});
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
	my $fh = $cb->([ 200, ['Content-Type' => 'application/atom+xml']]);
	my $ibx = $ctx->{-inbox};
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
		my $s = PublicInbox::Feed::feed_entry($feed_opts, $x, $ibx);
		$fh->write($s) if defined $s;
	}
	PublicInbox::Feed::end_feed($fh);
}

package PublicInbox::SearchQuery;
use strict;
use warnings;
use PublicInbox::Hval;
use PublicInbox::MID qw(mid_escape);

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

	my $q = mid_escape($self->{'q'});
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
