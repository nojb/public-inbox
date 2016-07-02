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
	PublicInbox::WwwStream->response($ctx, 200, sub {
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
	my $se_url =
	 'https://kernel.org/pub/software/scm/git/docs/git-send-email.html';
	my $p_url =
	 'https://en.wikipedia.org/wiki/Posting_style#Interleaved_style';

	my ($arg, $link) = mailto_arg_link($hdr);
	push @$arg, '/path/to/YOUR_REPLY';
	$arg = join(" \\\n    ", '', @$arg);
	<<EOF
<pre
id=R>You may reply publically to <a
href=#t>this message</a> via
plain-text email using any one of the following methods:

* Save the following mbox file, import it into your mail client,
  and reply-to-all from there: <a
href=raw>mbox</a>

  Avoid top-posting and favor interleaved quoting:
  <a
href="$p_url">$p_url</a>

* Reply to all the recipients using the <b>--to</b>, <b>--cc</b>,
  and <b>--in-reply-to</b> switches of git-send-email(1):

  git send-email$arg

  <a
href="$se_url">$se_url</a>

* If your mail client supports setting the <b>In-Reply-To</b> header
  via mailto: links, try the <a
href="$link">mailto: link</a></pre>
EOF
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
	my ($mime, $ctx, $more) = @_;
	my $srch = $ctx->{srch};
	my $hdr = $mime->header_obj;
	my $subj = $hdr->header('Subject');

	my $mid_raw = mid_clean(mid_mime($mime));
	my $id = id_compress($mid_raw, 1);
	my $id_m = 'm'.$id;
	my $mid = PublicInbox::Hval->new_msgid($mid_raw);

	my $root_anchor = $ctx->{root_anchor} || '';
	my $irt = in_reply_to($hdr);

	my $rv = "<a\nhref=#e$id\nid=m$id>*</a> ";
	$subj = '<b>'.ascii_html($subj).'</b>';
	$subj = "<u\nid=u>$subj</u>" if $root_anchor eq $id_m;
	$rv .= $subj . "\n";
	$rv .= _th_index_lite($mid_raw, $irt, $id, $ctx);
	my @tocc;
	foreach my $f (qw(To Cc)) {
		my $dst = _hdr_names($hdr, $f);
		push @tocc, "$f: $dst" if $dst ne '';
	}
	$rv .= "From: "._hdr_names($hdr, 'From').' @ '._msg_date($hdr)." UTC";
	my $upfx = $ctx->{-upfx};
	my $mhref = $upfx . $mid->as_href . '/';
	$rv .= qq{ (<a\nhref="$mhref">permalink</a> / };
	$rv .= qq{<a\nhref="${mhref}raw">raw</a>)\n};
	$rv .= '  '.join('; +', @tocc) . "\n" if @tocc;

	my $mapping = $ctx->{mapping};
	if (!$mapping && $irt) {
		my $mirt = PublicInbox::Hval->new_msgid($irt);
		my $href = $upfx . $mirt->as_href . '/';
		my $html = $mirt->as_html;
		$rv .= qq(In-Reply-To: &lt;<a\nhref="$href">$html</a>&gt;\n)
	}
	$rv .= "\n";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub { $rv .= add_text_body($mhref, $_[0]) });

	# add the footer
	$rv .= "\n<a\nhref=#$id_m\nid=e$id>^</a> ".
		"<a\nhref=\"$mhref\">permalink</a>" .
		" / <a\nhref=\"${mhref}raw\">raw</a>" .
		" / <a\nhref=\"${mhref}#R\">reply</a>";
	if (my $pct = $ctx->{pct}) { # used by SearchView.pm
		$rv .= " [relevance $pct->{$mid_raw}%]";
	} elsif ($mapping) {
		my $threaded = 'threaded';
		my $flat = 'flat';
		my $end = '';
		if ($ctx->{flat}) {
			$flat = "<b>$flat</b>";
		} else {
			$threaded = "<b>$threaded</b>";
		}
		$rv .= " / [<a\nhref=\"${mhref}T/#u\">$flat</a>";
		$rv .= "|<a\nhref=\"${mhref}t/#u\">$threaded</a>]";
		$rv .= " / <a\nhref=#r$id>$ctx->{s_nr}</a>";
	}

	$rv .= $more ? "\n\n" : "\n";
}

sub pad_link ($$;$) {
	my ($mid, $level, $s) = @_;
	$s ||= '...';
	my $id = id_compress($mid, 1);
	(' 'x19).indent_for($level).th_pfx($level)."<a\nhref=#r$id>($s)</a>\n";
}

sub _th_index_lite {
	my ($mid_raw, $irt, $id, $ctx) = @_;
	my $rv = '';
	my $mapping = $ctx->{mapping} or return $rv;
	my $pad = '  ';
	# map = [children, attr, node, idx, level]
	my $map = $mapping->{$mid_raw};
	my $nr_c = scalar @{$map->[0]};
	my $nr_s = 0;
	my $level = $map->[4];
	my $idx = $map->[3];
	if (defined $irt) {
		my $irt_map = $mapping->{$irt};
		my $siblings = $irt_map->[0];
		$nr_s = scalar(@$siblings) - 1;
		$rv .= $pad . $irt_map->[1];
		if ($idx > 0) {
			my $prev = $siblings->[$idx - 1];
			my $pmid = $prev->messageid;
			if ($idx > 2) {
				my $s = ($idx - 1). ' preceding siblings ...';
				$rv .= pad_link($pmid, $level, $s);
			} elsif ($idx == 2) {
				my $ppmid = $siblings->[0]->messageid;
				$rv .= $pad . $mapping->{$ppmid}->[1];
			}
			$rv .= $pad . $mapping->{$pmid}->[1];
		}
	}
	my $s_s = nr_to_s($nr_s, 'sibling', 'siblings');
	my $s_c = nr_to_s($nr_c, 'reply', 'replies');
	my $this = $map->[1];
	$this =~ s!\n\z!</b>\n!s;
	$this =~ s!<a\nhref.*</a> !!s; # no point in duplicating subject
	$rv .= "<b>@ $this";
	my $node = $map->[2];
	if (my $child = $node->child) {
		my $cmid = $child->messageid;
		$rv .= $pad . $mapping->{$cmid}->[1];
		if ($nr_c > 2) {
			my $s = ($nr_c - 1). ' more replies';
			$rv .= pad_link($cmid, $level + 1, $s);
		} elsif (my $cn = $child->next) {
			$rv .= $pad . $mapping->{$cn->messageid}->[1];
		}
	}
	if (my $next = $node->next) {
		my $nmid = $next->messageid;
		$rv .= $pad . $mapping->{$nmid}->[1];
		my $nnext = $nr_s - $idx;
		if ($nnext > 2) {
			my $s = ($nnext - 1).' subsequent siblings';
			$rv .= pad_link($nmid, $level, $s);
		} elsif (my $nn = $next->next) {
			$rv .= $pad . $mapping->{$nn->messageid}->[1];
		}
	}
	$rv .= $pad ."<a\nhref=#r$id>$s_s, $s_c; $ctx->{s_nr}</a>\n";
}

sub walk_thread {
	my ($th, $ctx, $cb) = @_;
	my @q = map { (0, $_) } $th->rootset;
	while (@q) {
		my $level = shift @q;
		my $node = shift @q or next;
		$cb->($ctx, $level, $node);
		unshift @q, $level+1, $node->child, $level, $node->next;
	}
}

sub pre_thread  {
	my ($ctx, $level, $node) = @_;
	my $mapping = $ctx->{mapping};
	my $idx = -1;
	if (my $parent = $node->parent) {
		my $m = $mapping->{$parent->messageid}->[0];
		$idx = scalar @$m;
		push @$m, $node;
	}
	$mapping->{$node->messageid} = [ [], '', $node, $idx, $level ];
	skel_dump($ctx, $level, $node);
}

sub thread_index_entry {
	my ($ctx, $level, $mime) = @_;
	my ($beg, $end) = thread_adj_level($ctx, $level);
	$beg . '<pre>' . index_entry($mime, $ctx, 0) . '</pre>' . $end;
}

sub stream_thread ($$) {
	my ($th, $ctx) = @_;
	my $inbox = $ctx->{-inbox};
	my $mime;
	my @q = map { (0, $_) } $th->rootset;
	my $level;
	while (@q) {
		$level = shift @q;
		my $node = shift @q or next;
		unshift @q, $level+1, $node->child, $level, $node->next;
		$mime = $inbox->msg_by_mid($node->messageid) and last;
	}
	return missing_thread($ctx) unless $mime;

	$mime = Email::MIME->new($mime);
	$ctx->{-title_html} = ascii_html($mime->header('Subject'));
	$ctx->{-html_tip} = thread_index_entry($ctx, $level, $mime);
	PublicInbox::WwwStream->response($ctx, 200, sub {
		return unless $ctx;
		while (@q) {
			$level = shift @q;
			my $node = shift @q or next;
			unshift @q, $level+1, $node->child, $level, $node->next;
			my $mid = $node->messageid;
			if ($mime = $inbox->msg_by_mid($mid)) {
				$mime = Email::MIME->new($mime);
				return thread_index_entry($ctx, $level, $mime);
			} else {
				return ghost_index_entry($ctx, $level, $mid);
			}
		}
		my $ret = join('', thread_adj_level($ctx, 0));
		$ret .= ${$ctx->{dst}}; # skel
		$ctx = undef;
		$ret;
	});
}

sub thread_html {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $sres = $ctx->{srch}->get_thread($mid, { asc => 1 });
	my $msgs = load_results($sres);
	my $nr = $sres->{total};
	return missing_thread($ctx) if $nr == 0;
	my $skel = '<hr /><pre>';
	$skel .= $nr == 1 ? 'only message in thread' : 'end of thread';
	$skel .= ", back to <a\nhref=\"../../\">index</a>";
	$skel .= "\n<a\nid=t>$nr+ messages in thread:</a> (download: ";
	$skel .= "<a\nhref=\"../t.mbox.gz\">mbox.gz</a>";
	$skel .= " / follow: <a\nhref=\"../t.atom\">Atom feed</a>)\n";
	$ctx->{-upfx} = '../../';
	$ctx->{cur_level} = 0;
	$ctx->{dst} = \$skel;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{root_anchor} = anchor_for($mid);
	$ctx->{seen} = {};
	$ctx->{mapping} = {};
	$ctx->{s_nr} = "$nr+ messages in thread";

	my $th = thread_results($msgs);
	walk_thread($th, $ctx, *pre_thread);
	$skel .= '</pre>';
	return stream_thread($th, $ctx) unless $ctx->{flat};

	# flat display: lazy load the full message from mini_mime:
	my $inbox = $ctx->{-inbox};
	my $mime;
	while ($mime = shift @$msgs) {
		$mime = $inbox->msg_by_mid(mid_clean(mid_mime($mime))) and last;
	}
	return missing_thread($ctx) unless $mime;
	$mime = Email::MIME->new($mime);
	$ctx->{-title_html} = ascii_html($mime->header('Subject'));
	$ctx->{-html_tip} = '<pre>'.index_entry($mime, $ctx, scalar @$msgs);
	$mime = undef;
	PublicInbox::WwwStream->response($ctx, 200, sub {
		return unless $msgs;
		while ($mime = shift @$msgs) {
			$mid = mid_clean(mid_mime($mime));
			$mime = $inbox->msg_by_mid($mid) and last;
		}
		if ($mime) {
			$mime = Email::MIME->new($mime);
			return index_entry($mime, $ctx, scalar @$msgs);
		}
		$msgs = undef;
		'</pre>'.$skel;
	});
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
	my $expand = qq(<a\nhref="${tpfx}T/#u">expand</a> ) .
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
	$ctx->{seen} = { $subj => 1 };
	$ctx->{cur} = $mid;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{dst} = $dst;
	walk_thread(thread_results(load_results($sres)), $ctx, *skel_dump);
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
	my ($ctx, $hdr, $level) = @_;

	my $dst = $ctx->{dst};
	my $cur = $ctx->{cur};
	my $mid = mid_clean($hdr->header_raw('Message-ID'));
	my $f = ascii_html($hdr->header('X-PI-From'));
	my $d = _msg_date($hdr) . ' ' . indent_for($level) . th_pfx($level);
	my $attr = $f;
	$ctx->{first_level} ||= $level;

	if ($attr ne $ctx->{prev_attr} || $ctx->{prev_level} > $level) {
		$ctx->{prev_attr} = $attr;
	} else {
		$attr = '';
	}
	$ctx->{prev_level} = $level;

	if ($cur) {
		if ($cur eq $mid) {
			delete $ctx->{cur};
			$$dst .= $d;
			$$dst .= "<b><a\nid=r\nhref=\"#t\">".
				 "$attr [this message]</a></b>\n";
			return;
		}
	} else {
		$ctx->{next_msg} ||= $mid;
	}

	# Subject is never undef, this mail was loaded from
	# our Xapian which would've resulted in '' if it were
	# really missing (and Filter rejects empty subjects)
	my $s = $hdr->header('Subject');
	my $h = $ctx->{srch}->subject_path($s);
	if ($ctx->{seen}->{$h}) {
		$s = undef;
	} else {
		$ctx->{seen}->{$h} = 1;
		$s = PublicInbox::Hval->new($s);
		$s = $s->as_html;
	}
	my $m = PublicInbox::Hval->new_msgid($mid);
	my $id = '';
	my $mapping = $ctx->{mapping};
	my $end = defined($s) ? "$s</a> $f\n" : "$f</a>\n";
	if ($mapping) {
		my $map = $mapping->{$mid};
		$id = id_compress($mid, 1);
		$m = '#m'.$id;
		$map->[1] = "$d<a\nhref=\"$m\">$end";
		$id = "\nid=r".$id;
	} else {
		$m = $ctx->{-upfx}.$m->as_href.'/';
	}
	$$dst .=  $d . "<a\nhref=\"$m\"$id>" . $end;
}

sub skel_dump {
	my ($ctx, $level, $node) = @_;
	if (my $mime = $node->message) {
		_skel_header($ctx, $mime->header_obj, $level);
	} else {
		my $mid = $node->messageid;
		my $dst = $ctx->{dst};
		my $mapping = $ctx->{mapping};
		my $map = $mapping->{$mid} if $mapping;
		if ($mid eq 'subject dummy') {
			my $ncp = "\t[no common parent]\n";
			$map->[1] = $ncp if $map;
			$$dst .= $ncp;
			return;
		}
		my $d = $ctx->{pct} ? '    [irrelevant] ' # search result
				    : '     [not found] ';
		$d .= indent_for($level) . th_pfx($level);
		my $upfx = $ctx->{-upfx};
		my $m = PublicInbox::Hval->new_msgid($mid);
		my $href = $upfx . $m->as_href . '/';
		my $html = $m->as_html;

		if ($map) {
			my $id = id_compress($mid, 1);
			$map->[1] = $d . qq{&lt;<a\nhref=#r$id>$html</a>&gt;\n};
			$d .= qq{&lt;<a\nhref="$href"\nid=r$id>$html</a>&gt;\n};
		} else {
			$d .= qq{&lt;<a\nhref="$href">$html</a>&gt;\n};
		}
		$$dst .= $d;
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
	my ($ctx, $level, $node) = @_;
	my $srch = $ctx->{srch};
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
	if (++$ctx->{subjs}->{$subj} == 1) {
		push @{$ctx->{order}}, [ $level, $subj ];
	}
	my $exist = $ctx->{latest}->{$subj};
	if (!$exist || $exist->[1] < $ts) {
		$ctx->{latest}->{$subj} = [ $mid, $ts ];
	}
}

sub emit_topics {
	my ($ctx) = @_;
	my $order = $ctx->{order};
	my $subjs = $ctx->{subjs};
	my $latest = $ctx->{latest};
	my $fh = $ctx->{fh};
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
		$cur->[1] .= "<a\nhref=\"$mid/T/#u\"><b>$subj</b></a>\n";
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
	my ($ctx) = @_;
	my ($off) = (($ctx->{qp}->{o} || '0') =~ /(\d+)/);
	$ctx->{order} = [];
	$ctx->{subjs} = {};
	$ctx->{latest} = {};
	my $max = 25;
	my %opts = ( offset => $off, limit => $max * 4 );
	while (scalar @{$ctx->{order}} < $max) {
		my $sres = $ctx->{srch}->query('', \%opts);
		my $nr = scalar @{$sres->{msgs}} or last;
		$sres = load_results($sres);
		walk_thread(thread_results($sres), $ctx, *add_topic);
		$opts{offset} += $nr;
	}

	emit_topics($ctx);
	$opts{offset};
}

sub thread_adj_level {
	my ($ctx, $level) = @_;

	my $max = $ctx->{cur_level};
	if ($level <= 0) {
		return ('', '') if $max == 0; # flat output

		# reset existing lists
		my $beg = $max > 1 ? ('</ul></li>' x ($max - 1)) : '';
		$ctx->{cur_level} = 0;
		("$beg</ul>", '');
	} elsif ($level == $max) { # continue existing list
		qw(<li> </li>);
	} elsif ($level < $max) {
		my $beg = $max > 1 ? ('</ul></li>' x ($max - $level)) : '';
		$ctx->{cur_level} = $level;
		("$beg<li>", '</li>');
	} else { # ($level > $max) # start a new level
		$ctx->{cur_level} = $level;
		my $beg = ($max ? '<li>' : '') . '<ul><li>';
		($beg, '</li>');
	}
}

sub ghost_index_entry {
	my ($ctx, $level, $mid) = @_;
	my ($beg, $end) = thread_adj_level($ctx,  $level);
	$beg . '<pre>'. ghost_parent($ctx->{-upfx}, $mid) . '</pre>' . $end;
}

1;
