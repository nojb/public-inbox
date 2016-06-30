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
use Plack::Util;
use PublicInbox::Hval qw/ascii_html/;
use PublicInbox::Linkify;
use PublicInbox::MID qw/mid_clean id_compress mid_mime/;
use PublicInbox::MsgIter;
use PublicInbox::Address;
use PublicInbox::WwwStream;
require POSIX;

use constant INDENT => '  ';
use constant TCHILD => '` ';
sub th_pfx ($) { $_[0] == 0 ? '' : TCHILD };

# public functions: (unstable)
sub msg_html {
	my ($ctx, $mime, $footer) = @_;
	my $hdr = $mime->header_obj;
	my $tip = _msg_html_prepare($hdr, $ctx);
	PublicInbox::WwwStream->new($ctx, sub {
		my ($nr, undef) = @_;
		if ($nr == 1) {
			$tip . multipart_text_as_html($mime, '') .
				'</pre><hr />'
		} elsif ($nr == 2) {
			# fake an EOF if generating the footer fails;
			# we want to at least show the message if something
			# here crashes:
			eval {
				'<pre>' . html_footer($hdr, 1, $ctx) .
				'</pre>' . msg_reply($ctx, $hdr)
			};
		} else {
			undef
		}
	});
}

# /$INBOX/$MESSAGE_ID/#R
sub msg_reply {
	my ($ctx, $hdr) = @_;
	my $se_url = 'https://git-htmldocs.bogomips.org/git-send-email.html';

	my ($arg, $link) = mailto_arg_link($hdr);
	push @$arg, '/path/to/YOUR_REPLY';

	"<pre\nid=R>".
	"You may reply publically to <a\nhref=#t>this message</a> via\n".
	"plain-text email using any one of the following methods:\n\n" .
	"* Save the following mbox file, import it into your mail client,\n" .
	"  and reply-to-all from there: <a\nhref=raw>mbox</a>\n\n" .
	"* Reply to all the recipients using the <b>--to</b>, <b>--cc</b>,\n" .
	"  and <b>--in-reply-to</b> switches of git-send-email(1):\n\n" .
	"  git send-email \\\n    " .
	join(" \\\n    ", @$arg ). "\n\n" .
	qq(  <a\nhref="$se_url">$se_url</a>\n\n) .
	"* If your mail client supports setting the <b>In-Reply-To</b>" .
	" header\n  via mailto: links, try the " .
	qq(<a\nhref="$link">mailto: link</a>\n) .
	'</pre>';
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

sub _hdr_names ($$) {
	my ($hdr, $field) = @_;
	my $val = $hdr->header($field) or return '';
	ascii_html(join(', ', PublicInbox::Address::names($val)));
}

sub nr_to_s ($$$) {
	my ($nr, $singular, $plural) = @_;
	return "0 $plural" if $nr == 0;
	$nr == 1 ? "$nr $singular" : "$nr $plural";
}

# this is already inside a <pre>
sub index_entry {
	my ($mime, $state) = @_;
	my $ctx = $state->{ctx};
	my $srch = $ctx->{srch};
	my $hdr = $mime->header_obj;
	my $subj = $hdr->header('Subject');

	my $mid_raw = mid_clean(mid_mime($mime));
	my $id = id_compress($mid_raw);
	my $id_m = 'm'.$id;
	my $mid = PublicInbox::Hval->new_msgid($mid_raw);

	my $root_anchor = $state->{root_anchor} || '';
	my $path = $root_anchor ? '../../' : '';
	my $href = $mid->as_href;
	my $irt = in_reply_to($hdr);

	$subj = '<b>'.ascii_html($subj).'</b>';
	$subj = "<u\nid=u>$subj</u>" if $root_anchor eq $id_m;

	my $ts = _msg_date($hdr);
	my $rv = "<a\nhref=#e$id\nid=$id_m>#</a> ";
	$rv .= $subj;
	my $mhref = $path.$href.'/';
	my $from = _hdr_names($hdr, 'From');
	$rv .= "\n- $from @ $ts UTC\n";
	my @tocc;
	foreach my $f (qw(To Cc)) {
		my $dst = _hdr_names($hdr, $f);
		push @tocc, "$f: $dst" if $dst ne '';
	}
	$rv .= '  '.join('; +', @tocc) . "\n" if @tocc;
	$rv .= "\n";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub { $rv .= add_text_body($mhref, $_[0]) });
	$rv .= "\n<a\nhref=\"$mhref\"\n>permalink</a>" .
		" / <a\nhref=\"${mhref}raw\">raw</a> / ";
	my $mapping = $state->{mapping};
	my $nr_c = $mapping->{$mid_raw} || 0;
	my $nr_s = 0;
	if (defined $irt) {
		$nr_s = ($mapping->{$irt} || 0) - 1;
		$nr_s = 0 if $nr_s < 0;
		$irt = anchor_for($irt);
		$rv .= "<a\nhref=#$irt>#parent</a>,";
	} else {
		$rv .= 'root message:';
	}
	$nr_s = nr_to_s($nr_s, 'sibling', 'siblings');
	$nr_c = nr_to_s($nr_c, 'reply', 'replies');
	$rv .= " <a\nhref=#r$id\nid=e$id>$nr_s, $nr_c</a>";
	$rv .= " / <a\nhref=\"${mhref}#R\">reply</a>";

	if (my $pct = $state->{pct}) { # used by SearchView.pm
		$rv .= " [relevance $pct->{$mid_raw}%]";
	}
	$rv .= "\n\n";
}

sub walk_thread {
	my ($th, $state, $cb) = @_;
	my @q = map { (0, $_) } $th->rootset;
	while (@q) {
		my $level = shift @q;
		my $node = shift @q or next;
		$cb->($state, $level, $node);
		unshift @q, $level+1, $node->child, $level, $node->next;
	}
}

sub pre_thread  {
	my ($state, $level, $node) = @_;
	my $parent = $node->parent;
	if ($parent) {
		my $mid = $parent->messageid;
		my $m = $state->{mapping};
		$m->{$mid} ||= 0;
		$m->{$mid}++;
	}
	skel_dump($state, $level, $node);
}

sub thread_html {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $sres = $ctx->{srch}->get_thread($mid, { asc => 1 });
	my $msgs = load_results($sres);
	my $nr = $sres->{total};
	return missing_thread($ctx) if $nr == 0;
	my $skel = '</pre><hr /><pre>';
	$skel .= $nr == 1 ? 'only message in thread' : 'end of thread';
	$skel .= ", back to <a\nhref=\"../../\">index</a>";
	$skel .= "\n<a\nid=t>$nr+ messages in thread:</a> (download: ";
	$skel .= "<a\nhref=\"../t.mbox.gz\">mbox.gz</a>";
	$skel .= " / follow: <a\nhref=\"../t.atom\">Atom feed</a>)\n";
	my $state = {
		ctx => $ctx,
		cur_level => 0,
		dst => \$skel,
		mapping => {}, # mid -> reply count
		prev_attr => '',
		prev_level => 0,
		root_anchor => anchor_for($mid),
		seen => {},
		srch => $ctx->{srch},
		upfx => '../../',
	};

	walk_thread(thread_results($msgs), $state, *pre_thread);

	# lazy load the full message from mini_mime:
	my $inbox = $ctx->{-inbox};
	my $mime;
	while ($mime = shift @$msgs) {
		$mime = $inbox->msg_by_mid(mid_clean(mid_mime($mime))) and last;
	}
	$mime = Email::MIME->new($mime);
	$ctx->{-upfx} = '../../';
	$ctx->{-title_html} = ascii_html($mime->header('Subject'));
	$ctx->{-html_tip} = '<pre>'.index_entry($mime, $state);
	$mime = undef;
	my $body = PublicInbox::WwwStream->new($ctx, sub {
		return unless $msgs;
		while ($mime = shift @$msgs) {
			$mid = mid_clean(mid_mime($mime));
			$mime = $inbox->msg_by_mid($mid) and last;
		}
		return index_entry(Email::MIME->new($mime), $state) if $mime;
		$msgs = undef;
		$skel .= "</pre>";
	});
	[ 200, ['Content-Type', 'text/html; charset=UTF-8'], $body ];
}

sub multipart_text_as_html {
	my ($mime, $upfx) = @_;
	my $rv = "";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub {
		my ($p) = @_;
		$rv .= add_text_body($upfx, $p);
	});
	$rv;
}

sub flush_quote {
	my ($s, $l, $quot) = @_;

	# show everything in the full version with anchor from
	# short version (see above)
	my $rv = $l->linkify_1(join('', @$quot));
	@$quot = ();

	# we use a <span> here to allow users to specify their own
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
	join('', @ret, "</a>\n");
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
		$s .= "\n";
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

	my $end = "\n";
	if (@quot) {
		$end = '';
		flush_quote(\$s, $l, \@quot);
	}
	$s =~ s/[ \t]+$//sgm; # kill per-line trailing whitespace
	$s =~ s/\A\n+//s; # kill leading blank lines
	$s =~ s/\s+\z//s; # kill all trailing spaces
	$s .= $end;
}

sub _msg_html_prepare {
	my ($hdr, $ctx) = @_;
	my $srch = $ctx->{srch} if $ctx;
	my $atom = '';
	my $rv = "<pre\nid=b>"; # anchor for body start

	if ($srch) {
		$ctx->{-upfx} = '../';
	}
	my @title;
	my $mid = $hdr->header_raw('Message-ID');
	$mid = PublicInbox::Hval->new_msgid($mid);
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $hdr->header($h);
		defined($v) && ($v ne '') or next;
		$v = PublicInbox::Hval->new($v);

		if ($h eq 'From') {
			my @n = PublicInbox::Address::names($v->raw);
			$title[1] = ascii_html(join(', ', @n));
		} elsif ($h eq 'Subject') {
			$title[0] = $v->as_html;
			if ($srch) {
				$rv .= qq($h: <a\nhref="#r"\nid=t>);
				$rv .= $v->as_html . "</a>\n";
				next;
			}
		}
		$v = $v->as_html;
		$v =~ s/(\@[^,]+,) /$1\n\t/g if ($h eq 'Cc' || $h eq 'To');
		$rv .= "$h: $v\n";

	}
	$title[0] ||= '(no subject)';
	$ctx->{-title_html} = join(' - ', @title);
	$rv .= 'Message-ID: &lt;' . $mid->as_html . '&gt; ';
	$rv .= "(<a\nhref=\"raw\">raw</a>)\n";
	$rv .= _parent_headers($hdr, $srch);
	$rv .= "\n";
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
		upfx => "$tpfx../",
		dst => $dst,
	};
	walk_thread(thread_results(load_results($sres)), $state, *skel_dump);
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
			$rv .= 'References: '. join("\n\t", @refs) . "\n";
		}
	}
	$rv;
}

sub squote_maybe ($) {
	my ($val) = @_;
	if ($val =~ m{([^\w@\./,\%\+\-])}) {
		$val =~ s/(['!])/'\\$1'/g; # '!' for csh
		return "'$val'";
	}
	$val;
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
	push @arg, '--in-reply-to='.ascii_html(squote_maybe(mid_clean($mid)));
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

	(\@arg, ascii_html($href));
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
			$irt = "<a\nhref=\"$upfx$p/\"\nrel=prev>parent</a> ";
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
	$rhref ||= '#R';
	$irt .= qq(<a\nhref="$rhref">reply</a>);
	$irt .= $idx;
}

sub linkify_ref_nosrch {
	my $v = PublicInbox::Hval->new_msgid($_[0], 1);
	my $html = $v->as_html;
	my $href = $v->as_href;
	"&lt;<a\nhref=\"../$href/\">$html</a>&gt;";
}

sub anchor_for {
	my ($msgid) = @_;
	'm' . id_compress($msgid, 1);
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

sub indent_for {
	my ($level) = @_;
	INDENT x ($level - 1);
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
	my ($ctx) = @_;
	require PublicInbox::ExtMsg;
	PublicInbox::ExtMsg::ext_msg($ctx);
}

sub _msg_date {
	my ($hdr) = @_;
	my $ts = $hdr->header('X-PI-TS') || msg_timestamp($hdr);
	fmt_ts($ts);
}

sub fmt_ts { POSIX::strftime('%Y-%m-%d %k:%M', gmtime($_[0])) }

sub _skel_header {
	my ($state, $hdr, $level) = @_;

	my $dst = $state->{dst};
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
	my $id = '';
	if ($state->{mapping}) {
		$id = id_compress($mid, 1);
		$m = '#m'.$id;
		$id = "\nid=r".$id;
	} else {
		$m = $state->{upfx}.$m->as_href.'/';
	}
	$$dst .= "$pfx<a\nhref=\"$m\"$id>";
	$$dst .= defined($s) ? "$s</a> $f\n" : "$f</a>\n";
}

sub skel_dump {
	my ($state, $level, $node) = @_;
	if (my $mime = $node->message) {
		_skel_header($state, $mime->header_obj, $level);
	} else {
		my $mid = $node->messageid;
		my $dst = $state->{dst};
		if ($mid eq 'subject dummy') {
			$$dst .= "\t[no common parent]\n";
			return;
		}
		if ($state->{pct}) { # search result
			$$dst .= '    [irrelevant] ';
		} else {
			$$dst .= '     [not found] ';
		}
		$$dst .= indent_for($level) . th_pfx($level);
		my $upfx = $state->{upfx};
		my $id = '';
		if ($state->{mapping}) { # thread index view
			$id = "\nid=".anchor_for($mid);
		}
		$mid = PublicInbox::Hval->new_msgid($mid);
		my $href = $upfx . $mid->as_href . '/';
		my $html = $mid->as_html;
		$$dst .= qq{&lt;<a\nhref="$href"$id>$html</a>&gt;\n};
	}
}

sub sort_ts {
	sort {
		(eval { $a->topmost->message->header('X-PI-TS') } || 0) <=>
		(eval { $b->topmost->message->header('X-PI-TS') } || 0)
	} @_;
}

sub _tryload_ghost ($$) {
	my ($srch, $mid) = @_;
	my $smsg = $srch->lookup_mail($mid) or return;
	$smsg->mini_mime;
}

# accumulate recent topics if search is supported
# returns 1 if done, undef if not
sub add_topic {
	my ($state, $level, $node) = @_;
	my $srch = $state->{srch};
	my $mid = $node->messageid;
	my $x = $node->message || _tryload_ghost($srch, $mid);
	my ($subj, $ts);
	if ($x) {
		$x = $x->header_obj;
		$subj = $x->header('Subject');
		$subj = $srch->subject_normalized($subj);
		$ts = $x->header('X-PI-TS');
	} else { # ghost message, do not bump level
		$ts = -666;
		$subj = "<$mid>";
	}
	if (++$state->{subjs}->{$subj} == 1) {
		push @{$state->{order}}, [ $level, $subj ];
	}
	my $exist = $state->{latest}->{$subj};
	if (!$exist || $exist->[1] < $ts) {
		$state->{latest}->{$subj} = [ $mid, $ts ];
	}
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
		$pfx = indent_for($level);
		my $nl = $level == $prev ? "\n" : '';
		if ($nl && $cur) {
			push @recent, $cur;
			$cur = undef;
		}
		$cur ||= [ $ts, '' ];
		$cur->[0] = $ts if $ts > $cur->[0];
		$cur->[1] .= $nl . $pfx . th_pfx($level);
		if ($ts == -666) { # ghost
			$cur->[1] .= ghost_parent('', $mid) . "\n";
			next; # child will have mbox / atom link
		}

		$subj = PublicInbox::Hval->new($subj)->as_html;
		$cur->[1] .= "<a\nhref=\"$mid/t/#u\"><b>$subj</b></a>\n";
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
		$sres = load_results($sres);
		walk_thread(thread_results($sres), $state, *add_topic);
		$opts{offset} += $nr;
	}

	emit_topics($state);
	$opts{offset};
}

1;
