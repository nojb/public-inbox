# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used for displaying the HTML web interface.
# See Documentation/design_www.txt for this.
package PublicInbox::View;
use strict;
use warnings;
use URI::Escape qw/uri_escape_utf8/;
use Date::Parse qw/str2time/;
use Encode::MIME::Header;
use PublicInbox::Hval qw/ascii_html/;
use PublicInbox::Linkify;
use PublicInbox::MID qw/mid_clean id_compress mid2path mid_mime/;
use PublicInbox::MsgIter;
use PublicInbox::Address;
require POSIX;

use constant INDENT => '  ';
use constant TCHILD => '` ';
sub th_pfx ($) { $_[0] == 0 ? '' : TCHILD };

# public functions:
sub msg_html {
	my ($ctx, $mime, $footer) = @_;
	$footer = defined($footer) ? "\n$footer" : '';
	my $hdr = $mime->header_obj;
	headers_to_html_header($hdr, $ctx) .
		multipart_text_as_html($mime, '') .
		'</pre><hr /><pre>' .
		html_footer($hdr, 1, $ctx, 'R/') .
		$footer .
		'</pre></body></html>';
}

# /$INBOX/$MESSAGE_ID/R/
sub msg_reply {
	my ($ctx, $hdr, $footer) = @_;
	my $s = $hdr->header('Subject');
	$s = '(no subject)' if (!defined $s) || ($s eq '');
	my $f = $hdr->header('From');
	$f = '' unless defined $f;
	my $mid = $hdr->header_raw('Message-ID');
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $t = ascii_html($s);
	my $se_url =
	 'https://kernel.org/pub/software/scm/git/docs/git-send-email.html';

	my ($arg, $link) = mailto_arg_link($hdr);
	push @$arg, '/path/to/YOUR_REPLY';

	"<html><head><title>replying to \"$t\"</title></head><body><pre>" .
	"replying to message:\n\n" .
	"Subject: <b>$t</b>\n" .
	"From: ". ascii_html($f) .
	"\nDate: " .  ascii_html($hdr->header('Date')) .
	"\nMessage-ID: &lt;" . $mid->as_html . "&gt;\n\n" .
	"There are multiple ways to reply:\n\n" .
	"* Save the following mbox file, import it into your mail client,\n" .
	"  and reply-to-all from there: <a\nhref=../raw>mbox</a>\n\n" .
	"* Reply to all the recipients using the <b>--to</b>, <b>--cc</b>,\n" .
	"  and <b>--in-reply-to</b> switches of git-send-email(1):\n\n" .
	"\tgit send-email \\\n\t\t" .
	join(" \\ \n\t\t", @$arg ). "\n\n" .
	qq(  <a\nhref="$se_url">$se_url</a>\n\n) .
	"* If your mail client supports setting the <b>In-Reply-To</b>" .
	" header\n  via mailto: links, try the " .
	qq(<a\nhref="$link">mailto: link</a>\n) .
	"\nFor context, the original <a\nhref=../>message</a> or " .
	qq(<a\nhref="../t/#u">thread</a>) .
	'</pre><hr /><pre>' . $footer .  '</pre></body></html>';
}

sub in_reply_to {
	my ($hdr) = @_;
	my $irt = $hdr->header_raw('In-Reply-To');

	return mid_clean($irt) if (defined $irt);

	my $refs = $hdr->header_raw('References');
	if ($refs && $refs =~ /<([^>]+)>\s*\z/s) {
		return $1;
	}
	undef;
}

# this is already inside a <pre>
sub index_entry {
	my ($mime, $level, $state) = @_;
	my $midx = $state->{anchor_idx}++;
	my $ctx = $state->{ctx};
	my $srch = $ctx->{srch};
	my $hdr = $mime->header_obj;
	my $subj = $hdr->header('Subject');

	my $mid_raw = mid_clean(mid_mime($mime));
	my $id = anchor_for($mid_raw);
	my $seen = $state->{seen};
	$seen->{$id} = "#$id"; # save the anchor for children, later

	my $mid = PublicInbox::Hval->new_msgid($mid_raw);
	my $from = PublicInbox::Address::from_name($hdr->header('From'));

	my $root_anchor = $state->{root_anchor} || '';
	my $path = $root_anchor ? '../../' : '';
	my $href = $mid->as_href;
	my $irt = in_reply_to($hdr);
	my $parent_anchor = $seen->{anchor_for($irt)} if defined $irt;

	$from = ascii_html($from);
	$subj = ascii_html($subj);
	$subj = "<a\nhref=\"${path}$href/\">$subj</a>";
	$subj = "<u\nid=u>$subj</u>" if $root_anchor eq $id;

	my $ts = _msg_date($hdr);
	my $rv = "<pre\nid=s$midx>";
	$rv .= "<b\nid=$id>$subj</b>\n";
	my $txt = "${path}$href/raw";
	my $fh = $state->{fh};
	$fh->write($rv .= "- $from @ $ts UTC (<a\nhref=\"$txt\">raw</a>)\n\n");

	my $mhref = "${path}$href/";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub { index_walk($fh, $mhref, $_[0]) });
	$rv = "\n" . html_footer($hdr, 0, $ctx, "$path$href/R/");

	if (defined $irt) {
		unless (defined $parent_anchor) {
			my $v = PublicInbox::Hval->new_msgid($irt, 1);
			$v = $v->as_href;
			$parent_anchor = "${path}$v/";
		}
		$rv .= " <a\nhref=\"$parent_anchor\">parent</a>";
	}
	if (my $pct = $state->{pct}) { # used by SearchView.pm
		$rv .= " [relevance $pct->{$mid_raw}%]";
	} elsif ($srch) {
		my $threaded = 'threaded';
		my $flat = 'flat';
		my $end = '';
		if ($ctx->{flat}) {
			$flat = "<b>$flat</b>";
			$end = "\n"; # for lynx
		} else {
			$threaded = "<b>$threaded</b>";
		}
		$rv .= " [<a\nhref=\"${path}$href/t/#u\">$threaded</a>";
		$rv .= "|<a\nhref=\"${path}$href/T/#u\">$flat</a>]$end";
	}
	$fh->write($rv .= '</pre>');
}

sub thread_html {
	my ($ctx, $foot, $srch) = @_;
	# $_[0] in sub is the Plack callback
	sub { emit_thread_html($_[0], $ctx, $foot, $srch) }
}

# only private functions below.

sub emit_thread_html {
	my ($res, $ctx, $foot, $srch) = @_;
	my $mid = $ctx->{mid};
	my $flat = $ctx->{flat};
	my $msgs = load_results($srch->get_thread($mid, { asc => $flat }));
	my $nr = scalar @$msgs;
	return missing_thread($res, $ctx) if $nr == 0;
	my $seen = {};
	my $state = {
		res => $res,
		ctx => $ctx,
		seen => $seen,
		root_anchor => anchor_for($mid),
		anchor_idx => 0,
		cur_level => 0,
	};

	require PublicInbox::Git;
	$ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	if ($flat) {
		pre_anchor_entry($seen, $_) for (@$msgs);
		__thread_entry($state, $_, 0) for (@$msgs);
	} else {
		my $th = thread_results($msgs);
		thread_entry($state, $_, 0) for $th->rootset;
		if (my $max = $state->{cur_level}) {
			$state->{fh}->write(
				('</ul></li>' x ($max - 1)) . '</ul>');
		}
	}

	# there could be a race due to a message being deleted in git
	# but still being in the Xapian index:
	my $fh = delete $state->{fh} or return missing_thread($res, $ctx);

	my $final_anchor = $state->{anchor_idx};
	my $next = "<a\nid=s$final_anchor>";
	$next .= $final_anchor == 1 ? 'only message in' : 'end of';
	$next .= " thread</a>, back to <a\nhref=\"../../\">index</a>";
	$next .= "\ndownload thread: ";
	$next .= "<a\nhref=\"../t.mbox.gz\">mbox.gz</a>";
	$next .= " / follow: <a\nhref=\"../t.atom\">Atom feed</a>";
	$fh->write('<hr /><pre>' . $next . "\n\n".
			$foot .  '</pre></body></html>');
	$fh->close;
}

sub index_walk {
	my ($fh, $upfx, $p) = @_;
	my $s = add_text_body($upfx, $p);

	return if $s eq '';

	$s .= "\n"; # ensure there's a trailing newline

	$fh->write($s);
}

sub multipart_text_as_html {
	my ($mime, $upfx) = @_;
	my $rv = "";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub {
		my ($p) = @_;
		$p = add_text_body($upfx, $p);
		$rv .= $p;
		$rv .= "\n" if $p ne '';
	});
	$rv;
}

sub flush_quote {
	my ($s, $l, $quot) = @_;

	# show everything in the full version with anchor from
	# short version (see above)
	my $rv = $l->linkify_1(join('', @$quot));
	@$quot = ();

	# we use a <div> here to allow users to specify their own
	# color for quoted text
	$rv = $l->linkify_2(ascii_html($rv));
	$$s .= qq(<span\nclass="q">) . $rv . '</span>'
}

sub attach_link ($$$$) {
	my ($upfx, $ct, $p, $fn) = @_;
	my ($part, $depth, @idx) = @$p;
	my $nl = $idx[-1] > 1 ? "\n" : '';
	my $idx = join('.', @idx);
	my $size = bytes::length($part->body);
	$ct ||= 'text/plain';
	$ct =~ s/;.*//; # no attributes
	$ct = ascii_html($ct);
	my $desc = $part->header('Content-Description');
	$desc = $fn unless defined $desc;
	$desc = '' unless defined $desc;
	my $sfn;
	if (defined $fn && $fn =~ /\A[[:alnum:]][\w\.-]+[[:alnum:]]\z/) {
		$sfn = $fn;
	} elsif ($ct eq 'text/plain') {
		$sfn = 'a.txt';
	} else {
		$sfn = 'a.bin';
	}
	my @ret = qq($nl<a\nhref="$upfx$idx-$sfn">[-- Attachment #$idx: );
	my $ts = "Type: $ct, Size: $size bytes";
	push(@ret, ($desc eq '') ? "$ts --]" : "$desc --]\n[-- $ts --]");
	join('', @ret, '</a>');
}

sub add_text_body {
	my ($upfx, $p) = @_; # from msg_iter: [ Email::MIME, depth, @idx ]
	my ($part, $depth, @idx) = @$p;
	my $ct = $part->content_type;
	my $fn = $part->filename;

	if (defined $ct && $ct =~ m!\btext/x?html\b!i) {
		return attach_link($upfx, $ct, $p, $fn);
	}

	my $s = eval { $part->body_str };

	# badly-encoded message? tell the world about it!
	return attach_link($upfx, $ct, $p, $fn) if $@;

	my @lines = split(/^/m, $s);
	$s = '';
	if (defined($fn) || $depth > 0) {
		$s .= attach_link($upfx, $ct, $p, $fn);
		$s .= "\n\n";
	}
	my @quot;
	my $l = PublicInbox::Linkify->new;
	while (defined(my $cur = shift @lines)) {
		if ($cur !~ /^>/) {
			# show the previously buffered quote inline
			flush_quote(\$s, $l, \@quot) if @quot;

			# regular line, OK
			$cur = $l->linkify_1($cur);
			$cur = ascii_html($cur);
			$s .= $l->linkify_2($cur);
		} else {
			push @quot, $cur;
		}
	}

	flush_quote(\$s, $l, \@quot) if @quot;
	$s =~ s/[ \t]+$//sgm; # kill per-line trailing whitespace
	$s =~ s/\A\n+//s; # kill leading blank lines
	$s =~ s/\s+\z//s; # kill all trailing spaces (final "\n" added if ne '')
	$s;
}

sub headers_to_html_header {
	my ($hdr, $ctx) = @_;
	my $srch = $ctx->{srch} if $ctx;
	my $atom = '';
	my $rv = '';
	my $upfx = '';

	if ($srch) {
		$atom = qq{<link\nrel=alternate\ntitle="Atom feed"\n} .
			qq!href="${upfx}t.atom"\ntype="application/atom+xml"/>!;
	}

	my @title;
	my $mid = $hdr->header_raw('Message-ID');
	$mid = PublicInbox::Hval->new_msgid($mid);
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $hdr->header($h);
		defined($v) && ($v ne '') or next;
		$v = PublicInbox::Hval->new($v);

		if ($h eq 'From') {
			$title[1] = PublicInbox::Address::from_name($v->raw);
		} elsif ($h eq 'Subject') {
			$title[0] = $v->as_html;
			if ($srch) {
				$rv .= qq($h: <a\nhref="#r"\nid=t>);
				$rv .= $v->as_html . "</a>\n";
				next;
			}
		}
		$rv .= "$h: " . $v->as_html . "\n";

	}
	$rv .= 'Message-ID: &lt;' . $mid->as_html . '&gt; ';
	$rv .= "(<a\nhref=\"${upfx}raw\">raw</a>)\n";
	$rv .= _parent_headers($hdr, $srch);
	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) . "</title>$atom".
	 PublicInbox::Hval::STYLE .
	 "</head><body><pre\nid=b>" . # anchor for body start
	 $rv);
}

sub thread_skel {
	my ($dst, $ctx, $hdr, $tpfx) = @_;
	my $srch = $ctx->{srch};
	my $mid = mid_clean($hdr->header_raw('Message-ID'));
	my $sres = $srch->get_thread($mid);
	my $nr = $sres->{total};
	my $expand = qq(<a\nhref="${tpfx}t/#u">expand</a> ) .
			qq(/ <a\nhref="${tpfx}t.mbox.gz">mbox.gz</a> ) .
			qq(/ <a\nhref="${tpfx}t.atom">Atom feed</a>);

	my $parent = in_reply_to($hdr);
	if ($nr <= 1) {
		if (defined $parent) {
			$$dst .= "($expand)\n ";
			$$dst .= ghost_parent("$tpfx../", $parent) . "\n";
		} else {
			$$dst .= "[no followups, yet] ($expand)\n";
		}
		$ctx->{next_msg} = undef;
		$ctx->{parent_msg} = $parent;
		return;
	}

	$$dst .= "$nr+ messages in thread ($expand";
	$$dst .= qq! / <a\nhref="#b">[top]</a>)\n!;

	my $subj = $srch->subject_path($hdr->header('Subject'));
	my $state = {
		seen => { $subj => 1 },
		srch => $srch,
		cur => $mid,
		prev_attr => '',
		prev_level => 0,
	};
	for (thread_results(load_results($sres))->rootset) {
		skel_dump($dst, $state, $tpfx, $_, 0);
	}
	$ctx->{next_msg} = $state->{next_msg};
	$ctx->{parent_msg} = $parent;
}

sub _parent_headers {
	my ($hdr, $srch) = @_;
	my $rv = '';

	my $irt = in_reply_to($hdr);
	if (defined $irt) {
		my $v = PublicInbox::Hval->new_msgid($irt, 1);
		my $html = $v->as_html;
		my $href = $v->as_href;
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a\nhref=\"../$href/\">$html</a>&gt;\n";
	}

	# do not display References: if search is present,
	# we show the thread skeleton at the bottom, instead.
	return $rv if $srch;

	my $refs = $hdr->header_raw('References');
	if ($refs) {
		# avoid redundant URLs wasting bandwidth
		my %seen;
		$seen{$irt} = 1 if defined $irt;
		my @refs;
		my @raw_refs = ($refs =~ /<([^>]+)>/g);
		foreach my $ref (@raw_refs) {
			next if $seen{$ref};
			$seen{$ref} = 1;
			push @refs, linkify_ref_nosrch($ref);
		}

		if (@refs) {
			$rv .= 'References: '. join(' ', @refs) . "\n";
		}
	}
	$rv;
}

sub mailto_arg_link {
	my ($hdr) = @_;
	my %cc; # everyone else
	my $to; # this is the From address

	foreach my $h (qw(From To Cc)) {
		my $v = $hdr->header($h);
		defined($v) && ($v ne '') or next;
		my @addrs = PublicInbox::Address::emails($v);
		foreach my $address (@addrs) {
			my $dst = lc($address);
			$cc{$dst} ||= $address;
			$to ||= $dst;
		}
	}
	my @arg;

	my $subj = $hdr->header('Subject') || '';
	$subj = "Re: $subj" unless $subj =~ /\bRe:/i;
	my $mid = $hdr->header_raw('Message-ID');
	push @arg, "--in-reply-to='" . ascii_html($mid) . "'";
	my $irt = uri_escape_utf8($mid);
	delete $cc{$to};
	push @arg, '--to=' . ascii_html($to);
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);
	my $cc = join(',', sort values %cc);
	push @arg, '--cc=' . ascii_html($cc);
	$cc = uri_escape_utf8($cc);
	my $href = "mailto:$to?In-Reply-To=$irt&Cc=${cc}&Subject=$subj";
	$href =~ s/%20/+/g;

	(\@arg, $href);
}

sub html_footer {
	my ($hdr, $standalone, $ctx, $rhref) = @_;

	my $srch = $ctx->{srch} if $ctx;
	my $upfx = '../';
	my $tpfx = '';
	my $idx = $standalone ? " <a\nhref=\"$upfx\">index</a>" : '';
	my $irt = '';
	if ($idx && $srch) {
		$idx .= "\n";
		thread_skel(\$idx, $ctx, $hdr, $tpfx);
		my $p = $ctx->{parent_msg};
		my $next = $ctx->{next_msg};
		if ($p) {
			$p = PublicInbox::Hval->new_msgid($p);
			$p = $p->as_href;
			$irt = "<a\nhref=\"$upfx$p/\"rel=prev>parent</a> ";
		} else {
			$irt = ' ' x length('parent ');
		}
		if ($next) {
			my $n = PublicInbox::Hval->new_msgid($next)->as_href;
			$irt .= "<a\nhref=\"$upfx$n/\"\nrel=next>next</a> ";
		} else {
			$irt .= ' ' x length('next ');
		}
	} else {
		$irt = '';
	}

	$irt . qq(<a\nhref="$rhref">reply</a>) . $idx;
}

sub linkify_ref_nosrch {
	my $v = PublicInbox::Hval->new_msgid($_[0], 1);
	my $html = $v->as_html;
	my $href = $v->as_href;
	"&lt;<a\nhref=\"../$href/\">$html</a>&gt;";
}

sub anchor_for {
	my ($msgid) = @_;
	my $id = $msgid;
	if ($id !~ /\A[a-f0-9]{40}\z/) {
		$id = id_compress(mid_clean($id), 1);
	}
	'm' . $id;
}

sub thread_html_head {
	my ($hdr, $state) = @_;
	my $res = delete $state->{res} or die "BUG: no Plack callback in {res}";
	my $fh = $res->([200, ['Content-Type'=> 'text/html; charset=UTF-8']]);
	$state->{fh} = $fh;

	my $s = ascii_html($hdr->header('Subject'));
	$fh->write("<html><head><title>$s</title>".
		qq{<link\nrel=alternate\ntitle="Atom feed"\n} .
		qq!href="../t.atom"\ntype="application/atom+xml"/>! .
		PublicInbox::Hval::STYLE .
		"</head><body>");
}

sub pre_anchor_entry {
	my ($seen, $mime) = @_;
	my $id = anchor_for(mid_mime($mime));
	$seen->{$id} = "#$id"; # save the anchor for children, later
}

sub ghost_parent {
	my ($upfx, $mid) = @_;
	# 'subject dummy' is used internally by Mail::Thread
	return '[no common parent]' if ($mid eq 'subject dummy');

	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $mid->as_href;
	my $html = $mid->as_html;
	qq{[parent not found: &lt;<a\nhref="$upfx$href/">$html</a>&gt;]};
}

sub thread_adj_level {
	my ($state, $level) = @_;

	my $max = $state->{cur_level};
	if ($level <= 0) {
		return '' if $max == 0; # flat output

		# reset existing lists
		my $x = $max > 1 ? ('</ul></li>' x ($max - 1)) : '';
		$state->{fh}->write($x . '</ul>');
		$state->{cur_level} = 0;
		return '';
	}
	if ($level == $max) { # continue existing list
		$state->{fh}->write('<li>');
	} elsif ($level < $max) {
		my $x = $max > 1 ? ('</ul></li>' x ($max - $level)) : '';
		$state->{fh}->write($x .= '<li>');
		$state->{cur_level} = $level;
	} else { # ($level > $max) # start a new level
		$state->{cur_level} = $level;
		$state->{fh}->write(($max ? '<li>' : '') . '<ul><li>');
	}
	'</li>';
}

sub ghost_flush {
	my ($state, $upfx, $mid, $level) = @_;
	my $end = '<pre>'. ghost_parent($upfx, $mid) . '</pre>';
	$state->{fh}->write($end .= thread_adj_level($state, $level));
}

sub __thread_entry {
	my ($state, $mime, $level) = @_;

	# lazy load the full message from mini_mime:
	$mime = eval {
		my $path = mid2path(mid_clean(mid_mime($mime)));
		Email::MIME->new($state->{ctx}->{git}->cat_file('HEAD:'.$path));
	} or return;

	thread_html_head($mime, $state) if $state->{anchor_idx} == 0;
	if (my $ghost = delete $state->{ghost}) {
		# n.b. ghost messages may only be parents, not children
		foreach my $g (@$ghost) {
			ghost_flush($state, '../../', @$g);
		}
	}
	my $end = thread_adj_level($state, $level);
	index_entry($mime, $level, $state);
	$state->{fh}->write($end) if $end;

	1;
}

sub indent_for {
	my ($level) = @_;
	INDENT x ($level - 1);
}

sub __ghost_prepare {
	my ($state, $node, $level) = @_;
	my $ghost = $state->{ghost} ||= [];
	push @$ghost, [ $node->messageid, $level ];
}

sub thread_entry {
	my ($state, $node, $level) = @_;
	return unless $node;
	if (my $mime = $node->message) {
		unless (__thread_entry($state, $mime, $level)) {
			__ghost_prepare($state, $node, $level);
		}
	} else {
		__ghost_prepare($state, $node, $level);
	}

	thread_entry($state, $node->child, $level + 1);
	thread_entry($state, $node->next, $level);
}

sub load_results {
	my ($sres) = @_;

	[ map { $_->mini_mime } @{delete $sres->{msgs}} ];
}

sub msg_timestamp {
	my ($hdr) = @_;
	my $ts = eval { str2time($hdr->header('Date')) };
	defined($ts) ? $ts : 0;
}

sub thread_results {
	my ($msgs) = @_;
	require PublicInbox::Thread;
	my $th = PublicInbox::Thread->new(@$msgs);
	$th->thread;
	$th->order(*sort_ts);
	$th
}

sub missing_thread {
	my ($res, $ctx) = @_;
	require PublicInbox::ExtMsg;

	$res->(PublicInbox::ExtMsg::ext_msg($ctx))
}

sub _msg_date {
	my ($hdr) = @_;
	my $ts = $hdr->header('X-PI-TS') || msg_timestamp($hdr);
	fmt_ts($ts);
}

sub fmt_ts { POSIX::strftime('%Y-%m-%d %k:%M', gmtime($_[0])) }

sub _skel_header {
	my ($dst, $state, $upfx, $hdr, $level) = @_;

	my $cur = $state->{cur};
	my $mid = mid_clean($hdr->header_raw('Message-ID'));
	my $f = ascii_html($hdr->header('X-PI-From'));
	my $d = _msg_date($hdr);
	my $pfx = "$d " . indent_for($level) . th_pfx($level);
	my $attr = $f;
	$state->{first_level} ||= $level;

	if ($attr ne $state->{prev_attr} || $state->{prev_level} > $level) {
		$state->{prev_attr} = $attr;
	} else {
		$attr = '';
	}
	$state->{prev_level} = $level;

	if ($cur) {
		if ($cur eq $mid) {
			delete $state->{cur};
			$$dst .= "$pfx<b><a\nid=r\nhref=\"#t\">".
				 "$attr [this message]</a></b>\n";

			return;
		}
	} else {
		$state->{next_msg} ||= $mid;
	}

	# Subject is never undef, this mail was loaded from
	# our Xapian which would've resulted in '' if it were
	# really missing (and Filter rejects empty subjects)
	my $s = $hdr->header('Subject');
	my $h = $state->{srch}->subject_path($s);
	if ($state->{seen}->{$h}) {
		$s = undef;
	} else {
		$state->{seen}->{$h} = 1;
		$s = PublicInbox::Hval->new($s);
		$s = $s->as_html;
	}
	my $m = PublicInbox::Hval->new_msgid($mid);
	$m = $upfx . '../' . $m->as_href . '/';
	$$dst .= "$pfx<a\nhref=\"$m\">";
	$$dst .= defined($s) ? "$s</a> $f\n" : "$f</a>\n";
}

sub skel_dump {
	my ($dst, $state, $upfx, $node, $level) = @_;
	return unless $node;
	if (my $mime = $node->message) {
		my $hdr = $mime->header_obj;
		my $mid = mid_clean($hdr->header_raw('Message-ID'));
		_skel_header($dst, $state, $upfx, $hdr, $level);
	} else {
		my $mid = $node->messageid;
		if ($mid eq 'subject dummy') {
			$$dst .= "\t[no common parent]\n";
		} else {
			$$dst .= '     [not found] ';
			$$dst .= indent_for($level) . th_pfx($level);
			$mid = PublicInbox::Hval->new_msgid($mid);
			my $href = "$upfx../" . $mid->as_href . '/';
			my $html = $mid->as_html;
			$$dst .= qq{&lt;<a\nhref="$href">$html</a>&gt;\n};
		}
	}
	skel_dump($dst, $state, $upfx, $node->child, $level+1);
	skel_dump($dst, $state, $upfx, $node->next, $level);
}

sub sort_ts {
	sort {
		(eval { $a->topmost->message->header('X-PI-TS') } || 0) <=>
		(eval { $b->topmost->message->header('X-PI-TS') } || 0)
	} @_;
}

# accumulate recent topics if search is supported
# returns 1 if done, undef if not
sub add_topic {
	my ($state, $node, $level) = @_;
	return unless $node;
	my $child_adjust = 1;

	if (my $x = $node->message) {
		$x = $x->header_obj;
		my $subj;

		$subj = $x->header('Subject');
		$subj = $state->{srch}->subject_normalized($subj);

		if (++$state->{subjs}->{$subj} == 1) {
			push @{$state->{order}}, [ $level, $subj ];
		}

		my $mid = mid_clean($x->header_raw('Message-ID'));

		my $ts = $x->header('X-PI-TS');
		my $exist = $state->{latest}->{$subj};
		if (!$exist || $exist->[1] < $ts) {
			$state->{latest}->{$subj} = [ $mid, $ts ];
		}
	} else {
		# ghost message, do not bump level
		$child_adjust = 0;
	}

	add_topic($state, $node->child, $level + $child_adjust);
	add_topic($state, $node->next, $level);
}

sub emit_topics {
	my ($state) = @_;
	my $order = $state->{order};
	my $subjs = $state->{subjs};
	my $latest = $state->{latest};
	my $fh = $state->{fh};
	return $fh->write("\n[No topics in range]</pre>") unless scalar @$order;
	my $pfx;
	my $prev = 0;
	my $prev_attr = '';
	my $cur;
	my @recent;
	while (defined(my $info = shift @$order)) {
		my ($level, $subj) = @$info;
		my $n = delete $subjs->{$subj};
		my ($mid, $ts) = @{delete $latest->{$subj}};
		$mid = PublicInbox::Hval->new_msgid($mid)->as_href;
		$subj = PublicInbox::Hval->new($subj)->as_html;
		$pfx = indent_for($level);
		my $nl = $level == $prev ? "\n" : '';
		if ($nl && $cur) {
			push @recent, $cur;
			$cur = undef;
		}
		$cur ||= [ $ts, '' ];
		$cur->[0] = $ts if $ts > $cur->[0];
		$cur->[1] .= $nl . $pfx . th_pfx($level) .
				"<a\nhref=\"$mid/t/#u\"><b>" .
				$subj . "</b></a>\n";

		$ts = fmt_ts($ts);
		my $attr = " $ts UTC";

		# $n isn't the total number of posts on the topic,
		# just the number of posts in the current results window
		$n = $n == 1 ? '' : " ($n+ messages)";

		if ($level == 0 || $attr ne $prev_attr) {
			my $mbox = qq(<a\nhref="$mid/t.mbox.gz">mbox.gz</a>);
			my $atom = qq(<a\nhref="$mid/t.atom">Atom</a>);
			$pfx .= INDENT if $level > 0;
			$cur->[1] .= $pfx . $attr . $n . " - $mbox / $atom\n";
			$prev_attr = $attr;
		}
	}
	push @recent, $cur if $cur;
	@recent = map { $_->[1] } sort { $b->[0] <=> $a->[0] } @recent;
	$fh->write(join('', @recent) . '</pre>');
}

sub emit_index_topics {
	my ($state) = @_;
	my ($off) = (($state->{ctx}->{cgi}->param('o') || '0') =~ /(\d+)/);
	$state->{order} = [];
	$state->{subjs} = {};
	$state->{latest} = {};
	my $max = 25;
	my %opts = ( offset => $off, limit => $max * 4 );
	while (scalar @{$state->{order}} < $max) {
		my $sres = $state->{srch}->query('', \%opts);
		my $nr = scalar @{$sres->{msgs}} or last;

		for (thread_results(load_results($sres))->rootset) {
			add_topic($state, $_, 0);
		}
		$opts{offset} += $nr;
	}

	emit_topics($state);
	$opts{offset};
}

1;
