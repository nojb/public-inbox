# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::SearchView;
use strict;
use warnings;
use PublicInbox::SearchMsg;
use PublicInbox::Hval;
use PublicInbox::View;
use POSIX qw/strftime/;
our $LIM = 25;

sub sres_top_html {
	my ($ctx, $q) = @_;
	my $cgi = $ctx->{cgi};
	my $code = 200;
	# $q ||= $cgi->param('q');
	my $o = int($cgi->param('o') || 0);
	my $r = $cgi->param('r');
	$r = (defined $r && $r ne '0');
	my $opts = { limit => $LIM, offset => $o, mset => 1, relevance => $r };
	my ($mset, $total);
	eval {
		$mset = $ctx->{srch}->query($q, $opts);
		$total = $mset->get_matches_estimated;
	};
	my $err = $@;
	my $query = PublicInbox::Hval->new_oneline($q);
	my $qh = $query->as_html;
	my $res = "<html><head><title>$qh - search results</title></head>" .
		  qq{<body><form\naction="">} .
		  qq{<input\nname=q\nvalue="$qh"\ntype=text />};

	$res .= qq{<input\ntype=hidden\nname=r />} if $r;

	$res .= qq{<input\ntype=submit\nvalue=search /></form>} .
		  PublicInbox::View::PRE_WRAP;

	my $foot = $ctx->{footer} || '';
	$foot = qq{Back to <a\nhref=".">index</a>.};
	if ($err) {
		my $u = 'http://xapian.org/docs/queryparser.html';
		$code = 400;
		$err =~ s/^\s*Exception:\s*//; # bad word to show users :P
		$err = PublicInbox::Hval->new_oneline($err)->as_html;
		$res .= "\n\nBad query: <b>$err</b>\n";
		$res .= qq{See <a\nhref="$u">$u</a> for Xapian query syntax};
		$res .= "</pre><hr /><pre>$foot";
	} elsif ($total == 0) {
		$code = 404;
		$res .= "\n\n[No results found]</pre><hr /><pre>$foot";
	} else {
		$q = $query->as_href;
		$q =~ s/%20/+/g; # improve URL readability
		my $qp = "?q=$q";
		$qp .= "&amp;o=$o" if $o;

		$res .= "Search results ordered by [";
		if ($r) {
			$res .= qq{<a\nhref="$qp">date</a>|<b>relevance</b>};
		} else {
			$qp .= '&amp;r';
			$res .= qq{<b>date</b>|<a\nhref="$qp">relevance</a>};
		}
		$res .= "]\n\n";

		dump_mset(\$res, $mset);
		my $nr = scalar $mset->items;
		my $end = $o + $nr;
		my $beg = $o + 1;
		$res .= "<hr /><pre>";
		$res .= "Results $beg-$end of $total";

		my $n = $o + $LIM;
		if ($n < $total) {
			$qp = "q=$q&amp;o=$n";
			$qp .= "&amp;r" if $r;
			$res .= qq{, <a\nhref="?$qp">next</a>}
		}
		if ($o > 0) {
			$res .= $n < $total ? '/' : ',      ';
			my $p = $o - $LIM;
			$qp = "q=$q";
			$qp .= "&amp;o=$p" if $p > 0;
			$qp .= "&amp;r" if $r;
			$res .= qq{<a\nhref="?$qp">prev</a>};
		}
		$res .= "\n\n" . $foot;
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
		my $d = strftime('%Y-%m-%d %H:%M', gmtime($smsg->ts));
		my $mid = PublicInbox::Hval->new_msgid($smsg->mid)->as_href;
		$$res .= qq{$rank. <b><a\nhref="$mid/t/#u">}.
			$s->as_html . "</a></b>\n";
		$$res .= "$pfx  - by $f @ $d UTC [$pct%]\n\n";
	}
}

1;
