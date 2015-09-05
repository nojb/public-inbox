# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::SearchView;
use strict;
use warnings;
use PublicInbox::SearchMsg;
use PublicInbox::Hval;
use PublicInbox::View;
use POSIX qw/strftime/;

sub sres_top_html {
	my ($ctx, $q) = @_;
	my $cgi = $ctx->{cgi};
	# $q ||= $cgi->param('q');
	my $o = int($cgi->param('o') || 0);
	my $r = $cgi->param('r');
	$r = (defined $r && $r ne '0');
	my $opts = { offset => $o, mset => 1, relevance => $r };
	my $mset = $ctx->{srch}->query($q, $opts);
	my $total = $mset->get_matches_estimated;
	my $query = PublicInbox::Hval->new_oneline($q);
	my $qh = $query->as_html;
	my $res = "<html><head><title>$qh - search results</title></head>" .
		  qq{<body><form\naction="">} .
		  qq{<input\nname=q\nvalue="$qh"\ntype=text />};

	$res .= qq{<input\ntype=hidden\nname=r />} if $r;

	$res .= qq{<input\ntype=submit\nvalue=search /></form>} .
		  PublicInbox::View::PRE_WRAP;

	my $foot = $ctx->{footer};
	if ($total == 0) {
		$foot ||= '';
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

		my $pad = length("$total");
		my $pfx = ' ' x $pad;
		foreach my $m ($mset->items) {
			my $rank = sprintf("%${pad}d", $m->get_rank + 1);
			my $pct = $m->get_percent;
			my $smsg = $m->get_document;
			$smsg = PublicInbox::SearchMsg->load_doc($smsg);
			my $s = PublicInbox::Hval->new_oneline($smsg->subject);
			my $f = $smsg->from_name;
			$f = PublicInbox::Hval->new_oneline($f)->as_html;
			my $d = strftime('%Y-%m-%d %H:%M', gmtime($smsg->ts));
			my $mid = $smsg->mid;
			$mid = PublicInbox::Hval->new_msgid($mid)->as_href;
			$res .= qq{$rank. <b><a\nhref="$mid/t/#u">}.
				$s->as_html . "</a></b>\n";
			$res .= "$pfx  - by $f @ $d UTC [$pct%]\n\n";
		}
		my $nr = scalar $mset->items;
		my $end = $o + $nr;
		my $beg = $o + 1;
		$res .= "<hr /><pre>";
		$res .= "Results $beg-$end of $total.";
		if ($nr < $total) {
			$o = $o + $nr;
			$qp = "q=$q&amp;o=$o";
			$qp .= "&amp;r" if $r;
			$res .= qq{ <a\nhref="?$qp">more</a>}
		}
		$res .= "\n\n".$foot if $foot;
	}

	$res .= "</pre></body></html>";
	[200, ['Content-Type'=>'text/html; charset=UTF-8'], [$res]];
}

sub sres_top_atom {
}

sub sres_top_thread {
}

1;
