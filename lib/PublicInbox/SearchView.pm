# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Displays search results for the web interface
package PublicInbox::SearchView;
use strict;
use warnings;
use URI::Escape qw(uri_unescape uri_escape);
use PublicInbox::SearchMsg;
use PublicInbox::Hval qw/ascii_html obfuscate_addrs/;
use PublicInbox::View;
use PublicInbox::WwwAtomStream;
use PublicInbox::MID qw(mid2path mid_mime mid_clean mid_escape MID_ESC);
use PublicInbox::MIME;
require PublicInbox::Git;
require PublicInbox::SearchThread;
our $LIM = 200;

sub noop {}

sub mbox_results {
	my ($ctx) = @_;
	my $q = PublicInbox::SearchQuery->new($ctx->{qp});
	my $x = $q->{x};
	return PublicInbox::Mbox::mbox_all($ctx, $q->{'q'}) if $x eq 'm';
	sres_top_html($ctx);
}

sub sres_top_html {
	my ($ctx) = @_;
	my $q = PublicInbox::SearchQuery->new($ctx->{qp});
	my $x = $q->{x};
	my $query = $q->{'q'};

	my $code = 200;
	# double the limit for expanded views:
	my $opts = {
		limit => $LIM,
		offset => $q->{o},
		mset => 1,
		relevance => $q->{r},
	};
	my ($mset, $total, $err, $cb);
retry:
	eval {
		$mset = $ctx->{srch}->query($query, $opts);
		$total = $mset->get_matches_estimated;
	};
	$err = $@;
	ctx_prepare($q, $ctx);
	if ($err) {
		$code = 400;
		$ctx->{-html_tip} = '<pre>'.err_txt($ctx, $err).'</pre><hr>';
		$cb = *noop;
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
		$ctx->{-html_tip} = "<pre>\n[No results found]</pre><hr>";
		$cb = *noop;
	} else {
		return adump($_[0], $mset, $q, $ctx) if $x eq 'A';

		$ctx->{-html_tip} = search_nav_top($mset, $q, $ctx);
		if ($x eq 't') {
			$cb = mset_thread($ctx, $mset, $q);
		} else {
			$cb = mset_summary($ctx, $mset, $q);
		}
	}
	PublicInbox::WwwStream->response($ctx, $code, $cb);
}

# allow undef for individual doc loads...
sub load_doc_retry {
	my ($srch, $mitem) = @_;

	eval {
		$srch->retry_reopen(sub {
			PublicInbox::SearchMsg->load_doc($mitem->get_document)
		});
	}
}

# display non-nested search results similar to what users expect from
# regular WWW search engines:
sub mset_summary {
	my ($ctx, $mset, $q) = @_;

	my $total = $mset->get_matches_estimated;
	my $pad = length("$total");
	my $pfx = ' ' x $pad;
	my $res = \($ctx->{-html_tip});
	my $srch = $ctx->{srch};
	my $ibx = $ctx->{-inbox};
	my $obfs_ibx = $ibx->{obfuscate} ? $ibx : undef;
	foreach my $m ($mset->items) {
		my $rank = sprintf("%${pad}d", $m->get_rank + 1);
		my $pct = $m->get_percent;
		my $smsg = load_doc_retry($srch, $m);
		unless ($smsg) {
			eval {
				$m = "$m ".$m->get_docid . " expired\n";
				$ctx->{env}->{'psgi.errors'}->print($m);
			};
			next;
		}
		my $s = ascii_html($smsg->subject);
		my $f = ascii_html($smsg->from_name);
		if ($obfs_ibx) {
			obfuscate_addrs($obfs_ibx, $s);
			obfuscate_addrs($obfs_ibx, $f);
		}
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
	my ($mset, $q, $ctx) = @_;
	my $m = $q->qs_html(x => 'm', r => undef);
	my $rv = qq{<form\naction="?$m"\nmethod="post"><pre>};
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
	if ($x eq '') {
		my $t = $q->qs_html(x => 't');
		$rv .= qq{<b>summary</b>|<a\nhref="?$t">nested</a>}
	} elsif ($q->{x} eq 't') {
		my $s = $q->qs_html(x => '');
		$rv .= qq{<a\nhref="?$s">summary</a>|<b>nested</b>};
	}
	my $A = $q->qs_html(x => 'A', r => undef);
	$rv .= qq{|<a\nhref="?$A">Atom feed</a>]};
	$rv .= qq{\n\t\t\t\t\t\tdownload: };
	$rv .= qq{<input\ntype=submit\nvalue="mbox.gz"/></pre></form><pre>};
}

sub search_nav_bot {
	my ($mset, $q) = @_;
	my $total = $mset->get_matches_estimated;
	my $nr = scalar $mset->items;
	my $o = $q->{o};
	my $end = $o + $nr;
	my $beg = $o + 1;
	my $rv = '</pre><hr><pre id=t>';
	if ($beg <= $end) {
		$rv .= "Results $beg-$end of $total";
		$rv .= ' (estimated)' if $end != $total;
	} else {
		$rv .= "No more results, only $total";
	}
	my $n = $o + $LIM;

	if ($n < $total) {
		my $qs = $q->qs_html(o => $n);
		$rv .= qq{  <a\nhref="?$qs"\nrel=next>next</a>}
	}
	if ($o > 0) {
		$rv .= $n < $total ? '/' : '       ';
		my $p = $o - $LIM;
		my $qs = $q->qs_html(o => ($p > 0 ? $p : 0));
		$rv .= qq{<a\nhref="?$qs"\nrel=prev>prev</a>};
	}
	$rv .= '</pre>';
}

sub sort_relevance {
	my ($pct) = @_;
	sub {
		[ sort { (eval { $pct->{$b->topmost->{id}} } || 0)
				<=>
			(eval { $pct->{$a->topmost->{id}} } || 0)
	} @{$_[0]} ] };
}

sub mset_thread {
	my ($ctx, $mset, $q) = @_;
	my %pct;
	my $srch = $ctx->{srch};
	my $msgs = $srch->retry_reopen(sub { [ map {
		my $i = $_;
		my $smsg = PublicInbox::SearchMsg->load_doc($i->get_document);
		$pct{$smsg->mid} = $i->get_percent;
		$smsg;
	} ($mset->items) ]});
	my $r = $q->{r};
	my $rootset = PublicInbox::SearchThread::thread($msgs,
		$r ? sort_relevance(\%pct) : *PublicInbox::View::sort_ts,
		$srch);
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
	$ctx->{s_nr} = scalar(@$msgs).'+ results';

	# reduce hash lookups in skel_dump
	$ctx->{-obfuscate} = $ctx->{-inbox}->{obfuscate};
	PublicInbox::View::walk_thread($rootset, $ctx,
		*PublicInbox::View::pre_thread);

	@$msgs = reverse @$msgs if $r;
	my $mime;
	sub {
		return unless $msgs;
		while ($mime = pop @$msgs) {
			$mime = $inbox->msg_by_smsg($mime) and last;
		}
		if ($mime) {
			$mime = PublicInbox::MIME->new($mime);
			return PublicInbox::View::index_entry($mime, $ctx,
				scalar @$msgs);
		}
		$msgs = undef;
		$skel .= "\n</pre>";
	};
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
	my $ibx = $ctx->{-inbox};
	my @items = $mset->items;
	$ctx->{search_query} = $q;
	my $srch = $ctx->{srch};
	PublicInbox::WwwAtomStream->response($ctx, 200, sub {
		while (my $x = shift @items) {
			$x = load_doc_retry($srch, $x);
			$x = $ibx->msg_by_smsg($x) and
					return PublicInbox::MIME->new($x);
		}
		return undef;
	});
}

package PublicInbox::SearchQuery;
use strict;
use warnings;
use URI::Escape qw(uri_escape);
use PublicInbox::Hval;
use PublicInbox::MID qw(MID_ESC);

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

	my $q = uri_escape($self->{'q'}, MID_ESC);
	$q =~ s/%20/+/g; # improve URL readability
	my $qs = "q=$q";

	if (my $o = $self->{o}) { # ignore o == 0
		$qs .= "&amp;o=$o";
	}
	if (my $r = $self->{r}) {
		$qs .= "&amp;r";
	}
	if (my $x = $self->{x}) {
		$qs .= "&amp;x=$x" if ($x eq 't' || $x eq 'A' || $x eq 'm');
	}
	$qs;
}

1;
