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
use PublicInbox::Hval qw/ascii_html/;
use PublicInbox::Linkify;
use PublicInbox::MID qw/mid_clean id_compress mid_mime mid_escape/;
use PublicInbox::MsgIter;
use PublicInbox::Address;
use PublicInbox::WwwStream;
require POSIX;

use constant INDENT => '  ';
use constant TCHILD => '` ';
sub th_pfx ($) { $_[0] == 0 ? '' : TCHILD };

# public functions: (unstable)
sub msg_html {
	my ($ctx, $mime) = @_;
	my $hdr = $mime->header_obj;
	my $tip = _msg_html_prepare($hdr, $ctx);
	PublicInbox::WwwStream->response($ctx, 200, sub {
		my ($nr, undef) = @_;
		if ($nr == 1) {
			$tip . multipart_text_as_html($mime, '') . '</pre><hr>'
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

	my $info = '';
	if (my $url = $ctx->{-inbox}->{infourl}) {
		$url = PublicInbox::Hval::prurl($ctx->{env}, $url);
		$info = qq(\n  List information: <a\nhref="$url">$url</a>\n);
	}

	my ($arg, $link) = mailto_arg_link($hdr);
	push @$arg, '/path/to/YOUR_REPLY';
	$arg = ascii_html(join(" \\\n    ", '', @$arg));
	<<EOF
<hr><pre
id=R><b>Reply instructions:</b>

You may reply publically to <a
href=#t>this message</a> via plain-text email
using any one of the following methods:

* Save the following mbox file, import it into your mail client,
  and reply-to-all from there: <a
href=raw>mbox</a>

  Avoid top-posting and favor interleaved quoting:
  <a
href="$p_url">$p_url</a>
$info
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

	return mid_clean($irt) if defined $irt && $irt ne '';

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

	my $root_anchor = $ctx->{root_anchor} || '';
	my $irt;

	my $rv = "<a\nhref=#e$id\nid=m$id>*</a> ";
	$subj = '<b>'.ascii_html($subj).'</b>';
	$subj = "<u\nid=u>$subj</u>" if $root_anchor eq $id_m;
	$rv .= $subj . "\n";
	$rv .= _th_index_lite($mid_raw, \$irt, $id, $ctx);
	my @tocc;
	foreach my $f (qw(To Cc)) {
		my $dst = _hdr_names($hdr, $f);
		push @tocc, "$f: $dst" if $dst ne '';
	}
	$rv .= "From: "._hdr_names($hdr, 'From').' @ '._msg_date($hdr)." UTC";
	my $upfx = $ctx->{-upfx};
	my $mhref = $upfx . mid_escape($mid_raw) . '/';
	$rv .= qq{ (<a\nhref="$mhref">permalink</a> / };
	$rv .= qq{<a\nhref="${mhref}raw">raw</a>)\n};
	$rv .= '  '.join('; +', @tocc) . "\n" if @tocc;

	my $mapping = $ctx->{mapping};
	if (!$mapping && (defined($irt) || defined($irt = in_reply_to($hdr)))) {
		my $mirt = PublicInbox::Hval->new_msgid($irt);
		my $href = $upfx . $mirt->{href}. '/';
		my $html = $mirt->as_html;
		$rv .= qq(In-Reply-To: &lt;<a\nhref="$href">$html</a>&gt;\n)
	}
	$rv .= "\n";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub { $rv .= add_text_body($mhref, $_[0]) });

	# add the footer
	$rv .= "\n<a\nhref=#$id_m\nid=e$id>^</a> ".
		"<a\nhref=\"$mhref\">permalink</a>" .
		" <a\nhref=\"${mhref}raw\">raw</a>" .
		" <a\nhref=\"${mhref}#R\">reply</a>";

	my $hr;
	if (my $pct = $ctx->{pct}) { # used by SearchView.pm
		$rv .= "\t[relevance $pct->{$mid_raw}%]";
		$hr = 1;
	} elsif ($mapping) {
		my $threaded = 'threaded';
		my $flat = 'flat';
		my $end = '';
		if ($ctx->{flat}) {
			$hr = 1;
			$flat = "<b>$flat</b>";
		} else {
			$threaded = "<b>$threaded</b>";
		}
		$rv .= "\t[<a\nhref=\"${mhref}T/#u\">$flat</a>";
		$rv .= "|<a\nhref=\"${mhref}t/#u\">$threaded</a>]";
		$rv .= " <a\nhref=#r$id>$ctx->{s_nr}</a>";
	} else {
		$hr = $ctx->{-hr};
	}

	$rv .= $more ? '</pre><hr><pre>' : '</pre>' if $hr;
	$rv;
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
	my ($attr, $node, $idx, $level) = @{$mapping->{$mid_raw}};
	my $children = $node->{children};
	my $nr_c = scalar @$children;
	my $nr_s = 0;
	my $siblings;
	if (my $smsg = $node->{smsg}) {
		($$irt) = (($smsg->{references} || '') =~ m/<([^>]+)>\z/);
	}
	my $irt_map = $mapping->{$$irt} if defined $$irt;
	if (defined $irt_map) {
		$siblings = $irt_map->[1]->{children};
		$nr_s = scalar(@$siblings) - 1;
		$rv .= $pad . $irt_map->[0];
		if ($idx > 0) {
			my $prev = $siblings->[$idx - 1];
			my $pmid = $prev->{id};
			if ($idx > 2) {
				my $s = ($idx - 1). ' preceding siblings ...';
				$rv .= pad_link($pmid, $level, $s);
			} elsif ($idx == 2) {
				my $ppmid = $siblings->[0]->{id};
				$rv .= $pad . $mapping->{$ppmid}->[0];
			}
			$rv .= $pad . $mapping->{$pmid}->[0];
		}
	}
	my $s_s = nr_to_s($nr_s, 'sibling', 'siblings');
	my $s_c = nr_to_s($nr_c, 'reply', 'replies');
	$attr =~ s!\n\z!</b>\n!s;
	$attr =~ s!<a\nhref.*</a> !!s; # no point in duplicating subject
	$attr =~ s!<a\nhref=[^>]+>([^<]+)</a>!$1!s; # no point linking to self
	$rv .= "<b>@ $attr";
	if ($nr_c) {
		my $cmid = $children->[0]->{id};
		$rv .= $pad . $mapping->{$cmid}->[0];
		if ($nr_c > 2) {
			my $s = ($nr_c - 1). ' more replies';
			$rv .= pad_link($cmid, $level + 1, $s);
		} elsif (my $cn = $children->[1]) {
			$rv .= $pad . $mapping->{$cn->{id}}->[0];
		}
	}

	my $next = $siblings->[$idx+1] if $siblings && $idx >= 0;
	if ($next) {
		my $nmid = $next->{id};
		$rv .= $pad . $mapping->{$nmid}->[0];
		my $nnext = $nr_s - $idx;
		if ($nnext > 2) {
			my $s = ($nnext - 1).' subsequent siblings';
			$rv .= pad_link($nmid, $level, $s);
		} elsif (my $nn = $siblings->[$idx + 2]) {
			$rv .= $pad . $mapping->{$nn->{id}}->[0];
		}
	}
	$rv .= $pad ."<a\nhref=#r$id>$s_s, $s_c; $ctx->{s_nr}</a>\n";
}

sub walk_thread {
	my ($th, $ctx, $cb) = @_;
	my @q = map { (0, $_, -1) } @{$th->{rootset}};
	while (@q) {
		my ($level, $node, $i) = splice(@q, 0, 3);
		defined $node or next;
		$cb->($ctx, $level, $node, $i);
		++$level;
		$i = 0;
		unshift @q, map { ($level, $_, $i++) } @{$node->{children}};
	}
}

sub pre_thread  {
	my ($ctx, $level, $node, $idx) = @_;
	$ctx->{mapping}->{$node->{id}} = [ '', $node, $idx, $level ];
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
	my @q = map { (0, $_) } @{$th->{rootset}};
	my $level;
	while (@q) {
		$level = shift @q;
		my $node = shift @q or next;
		my $cl = $level + 1;
		unshift @q, map { ($cl, $_) } @{$node->{children}};
		$mime = $inbox->msg_by_smsg($node->{smsg}) and last;
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
			my $cl = $level + 1;
			unshift @q, map { ($cl, $_) } @{$node->{children}};
			my $mid = $node->{id};
			if ($mime = $inbox->msg_by_smsg($node->{smsg})) {
				$mime = Email::MIME->new($mime);
				return thread_index_entry($ctx, $level, $mime);
			} else {
				return ghost_index_entry($ctx, $level, $node);
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
	my $srch = $ctx->{srch};
	my $sres = $srch->get_thread($mid);
	my $msgs = load_results($srch, $sres);
	my $nr = $sres->{total};
	return missing_thread($ctx) if $nr == 0;
	my $skel = '<hr><pre>';
	$skel .= $nr == 1 ? 'only message in thread' : 'end of thread';
	$skel .= ", back to <a\nhref=\"../../\">index</a>\n\n";
	$skel .= "<b\nid=t>Thread overview:</b> ";
	$skel .= $nr == 1 ? '(only message)' : "$nr+ messages";
	$skel .= " (download: <a\nhref=\"../t.mbox.gz\">mbox.gz</a>";
	$skel .= " / follow: <a\nhref=\"../t.atom\">Atom feed</a>)\n";
	$skel .= "-- links below jump to the message on this page --\n";
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

	# flat display: lazy load the full message from smsg
	my $inbox = $ctx->{-inbox};
	my $mime;
	while ($mime = shift @$msgs) {
		$mime = $inbox->msg_by_smsg($mime) and last;
	}
	return missing_thread($ctx) unless $mime;
	$mime = Email::MIME->new($mime);
	$ctx->{-title_html} = ascii_html($mime->header('Subject'));
	$ctx->{-html_tip} = '<pre>'.index_entry($mime, $ctx, scalar @$msgs);
	$mime = undef;
	PublicInbox::WwwStream->response($ctx, 200, sub {
		return unless $msgs;
		while ($mime = shift @$msgs) {
			$mime = $inbox->msg_by_smsg($mime) and last;
		}
		if ($mime) {
			$mime = Email::MIME->new($mime);
			return index_entry($mime, $ctx, scalar @$msgs);
		}
		$msgs = undef;
		$skel;
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

sub attach_link ($$$$;$) {
	my ($upfx, $ct, $p, $fn, $err) = @_;
	my ($part, $depth, @idx) = @$p;
	my $nl = $idx[-1] > 1 ? "\n" : '';
	my $idx = join('.', @idx);
	my $size = bytes::length($part->body);

	# hide attributes normally, unless we want to aid users in
	# spotting MUA problems:
	$ct =~ s/;.*// unless $err;
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
	my $ret = qq($nl<a\nhref="$upfx$idx-$sfn">);
	if ($err) {
		$ret .=
"[-- Warning: decoded text below may be mangled --]\n";
	}
	$ret .= "[-- Attachment #$idx: ";
	my $ts = "Type: $ct, Size: $size bytes";
	$ret .= ($desc eq '') ? "$ts --]" : "$desc --]\n[-- $ts --]";
	$ret .= "</a>\n";
}

sub add_text_body {
	my ($upfx, $p) = @_; # from msg_iter: [ Email::MIME, depth, @idx ]
	my ($part, $depth, @idx) = @$p;
	my $ct = $part->content_type || 'text/plain';
	my $fn = $part->filename;

	if ($ct =~ m!\btext/x?html\b!i) {
		return attach_link($upfx, $ct, $p, $fn);
	}

	my $s = eval { $part->body_str };

	# badly-encoded message? tell the world about it!
	my $err = $@;
	if ($err) {
		if ($ct =~ m!\btext/plain\b!i) {
			# Try to assume UTF-8 because Alpine seems to
			# do wacky things and set charset=X-UNKNOWN
			$part->charset_set('UTF-8');
			$s = eval { $part->body_str };

			# If forcing charset=UTF-8 failed,
			# attach_link will warn further down...
			$s = $part->body if $@;
		} else {
			return attach_link($upfx, $ct, $p, $fn);
		}
	}

	my @lines = split(/^/m, $s);
	$s = '';
	if (defined($fn) || $depth > 0 || $err) {
		$s .= attach_link($upfx, $ct, $p, $fn, $err);
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
	my $mid = mid_clean($hdr->header_raw('Message-ID'));
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
	$$dst .= "\n<b>Thread overview: </b>";
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
	$sres = load_results($srch, $sres);
	walk_thread(thread_results($sres), $ctx, *skel_dump);
	$ctx->{parent_msg} = $parent;
}

sub _parent_headers {
	my ($hdr, $srch) = @_;
	my $rv = '';

	my $irt = in_reply_to($hdr);
	if (defined $irt) {
		my $v = PublicInbox::Hval->new_msgid($irt);
		my $html = $v->as_html;
		my $href = $v->{href};
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
	push @arg, '--in-reply-to='.squote_maybe(mid_clean($mid));
	my $irt = mid_escape($mid);
	delete $cc{$to};
	push @arg, "--to=$to";
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);
	my @cc = sort values %cc;
	push(@arg, map { "--cc=$_" } @cc);
	my $cc = uri_escape_utf8(join(',', @cc));
	my $href = "mailto:$to?In-Reply-To=$irt&Cc=${cc}&Subject=$subj";

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
		my ($next, $prev);
		my $parent = '       ';
		$next = $prev = '    ';

		if (my $n = $ctx->{next_msg}) {
			$n = PublicInbox::Hval->new_msgid($n)->{href};
			$next = "<a\nhref=\"$upfx$n/\"\nrel=next>next</a>";
		}
		my $u;
		my $par = $ctx->{parent_msg};
		if ($par) {
			$u = PublicInbox::Hval->new_msgid($par)->{href};
			$u = "$upfx$u/";
		}
		if (my $p = $ctx->{prev_msg}) {
			$prev = PublicInbox::Hval->new_msgid($p)->{href};
			if ($p && $par && $p eq $par) {
				$prev = "<a\nhref=\"$upfx$prev/\"\n" .
					'rel=prev>prev parent</a>';
				$parent = '';
			} else {
				$prev = "<a\nhref=\"$upfx$prev/\"\n" .
					'rel=prev>prev</a>';
				$parent = " <a\nhref=\"$u\">parent</a>" if $u;
			}
		} elsif ($u) { # unlikely
			$parent = " <a\nhref=\"$u\"\nrel=prev>parent</a>";
		}
		$irt = "$next $prev$parent ";
	} else {
		$irt = '';
	}
	$rhref ||= '#R';
	$irt .= qq(<a\nhref="$rhref">reply</a>);
	$irt .= $idx;
}

sub linkify_ref_nosrch {
	my $v = PublicInbox::Hval->new_msgid($_[0]);
	my $html = $v->as_html;
	my $href = $v->{href};
	"&lt;<a\nhref=\"../$href/\">$html</a>&gt;";
}

sub anchor_for {
	my ($msgid) = @_;
	'm' . id_compress($msgid, 1);
}

sub ghost_parent {
	my ($upfx, $mid) = @_;

	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $mid->{href};
	my $html = $mid->as_html;
	qq{[parent not found: &lt;<a\nhref="$upfx$href/">$html</a>&gt;]};
}

sub indent_for {
	my ($level) = @_;
	INDENT x ($level - 1);
}

sub load_results {
	my ($srch, $sres) = @_;
	my $msgs = delete $sres->{msgs};
	$srch->retry_reopen(sub { [ map { $_->ensure_metadata; $_ } @$msgs ] });
}

sub msg_timestamp {
	my ($hdr) = @_;
	my $ts = eval { str2time($hdr->header('Date')) };
	defined($ts) ? $ts : 0;
}

sub thread_results {
	my ($msgs) = @_;
	require PublicInbox::SearchThread;
	my $th = PublicInbox::SearchThread->new($msgs);
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

sub skel_dump {
	my ($ctx, $level, $node) = @_;
	my $smsg = $node->{smsg} or return _skel_ghost($ctx, $level, $node);

	my $dst = $ctx->{dst};
	my $cur = $ctx->{cur};
	my $mid = $smsg->{mid};
	my $f = ascii_html($smsg->from_name);
	my $d = fmt_ts($smsg->{ts}) . ' ' . indent_for($level) . th_pfx($level);
	my $attr = $f;
	$ctx->{first_level} ||= $level;

	if ($attr ne $ctx->{prev_attr} || $ctx->{prev_level} > $level) {
		$ctx->{prev_attr} = $attr;
	}
	$ctx->{prev_level} = $level;

	if ($cur) {
		if ($cur eq $mid) {
			delete $ctx->{cur};
			$$dst .= "<b>$d<a\nid=r\nhref=\"#t\">".
				 "$attr [this message]</a></b>\n";
			return;
		} else {
			$ctx->{prev_msg} = $mid;
		}
	} else {
		$ctx->{next_msg} ||= $mid;
	}

	# Subject is never undef, this mail was loaded from
	# our Xapian which would've resulted in '' if it were
	# really missing (and Filter rejects empty subjects)
	my $s = $smsg->subject;
	my $h = $ctx->{srch}->subject_path($s);
	if ($ctx->{seen}->{$h}) {
		$s = undef;
	} else {
		$ctx->{seen}->{$h} = 1;
		$s = PublicInbox::Hval->new($s);
		$s = $s->as_html;
	}
	my $m;
	my $id = '';
	my $mapping = $ctx->{mapping};
	my $end = defined($s) ? "$s</a> $f\n" : "$f</a>\n";
	if ($mapping) {
		my $map = $mapping->{$mid};
		$id = id_compress($mid, 1);
		$m = '#m'.$id;
		$map->[0] = "$d<a\nhref=\"$m\">$end";
		$id = "\nid=r".$id;
	} else {
		$m = $ctx->{-upfx}.mid_escape($mid).'/';
	}
	$$dst .=  $d . "<a\nhref=\"$m\"$id>" . $end;
}

sub _skel_ghost {
	my ($ctx, $level, $node) = @_;

	my $mid = $node->{id};
	my $d = $ctx->{pct} ? '    [irrelevant] ' # search result
			    : '     [not found] ';
	$d .= indent_for($level) . th_pfx($level);
	my $upfx = $ctx->{-upfx};
	my $m = PublicInbox::Hval->new_msgid($mid);
	my $href = $upfx . $m->{href} . '/';
	my $html = $m->as_html;

	my $mapping = $ctx->{mapping};
	my $map = $mapping->{$mid} if $mapping;
	if ($map) {
		my $id = id_compress($mid, 1);
		$map->[0] = $d . qq{&lt;<a\nhref=#r$id>$html</a>&gt;\n};
		$d .= qq{&lt;<a\nhref="$href"\nid=r$id>$html</a>&gt;\n};
	} else {
		$d .= qq{&lt;<a\nhref="$href">$html</a>&gt;\n};
	}
	my $dst = $ctx->{dst};
	$$dst .= $d;
}

sub sort_ts {
	[ sort {
		(eval { $a->topmost->{smsg}->ts } || 0) <=>
		(eval { $b->topmost->{smsg}->ts } || 0)
	} @{$_[0]} ];
}

# accumulate recent topics if search is supported
# returns 200 if done, 404 if not
sub acc_topic {
	my ($ctx, $level, $node) = @_;
	my $srch = $ctx->{srch};
	my $mid = $node->{id};
	my $x = $node->{smsg} || $srch->lookup_mail($mid);
	my ($subj, $ts);
	my $topic;
	if ($x) {
		$subj = $x->subject;
		$subj = $srch->subject_normalized($subj);
		$ts = $x->ts;
		if ($level == 0) {
			$topic = [ $ts, 1, { $subj => $mid }, $subj ];
			$ctx->{-cur_topic} = $topic;
			push @{$ctx->{order}}, $topic;
			return;
		}

		$topic = $ctx->{-cur_topic}; # should never be undef
		$topic->[0] = $ts if $ts > $topic->[0];
		$topic->[1]++;
		my $seen = $topic->[2];
		if (scalar(@$topic) == 3) { # parent was a ghost
			push @$topic, $subj;
		} elsif (!$seen->{$subj}) {
			push @$topic, $level, $subj;
		}
		$seen->{$subj} = $mid; # latest for subject
	} else { # ghost message
		return if $level != 0; # ignore child ghosts
		$topic = [ -666, 0, {} ];
		$ctx->{-cur_topic} = $topic;
		push @{$ctx->{order}}, $topic;
	}
}

sub dump_topics {
	my ($ctx) = @_;
	my $order = delete $ctx->{order}; # [ ts, subj1, subj2, subj3, ... ]
	if (!@$order) {
		$ctx->{-html_tip} = '<pre>[No topics in range]</pre>';
		return 404;
	}

	my @out;

	# sort by recency, this allows new posts to "bump" old topics...
	foreach my $topic (sort { $b->[0] <=> $a->[0] } @$order) {
		my ($ts, $n, $seen, $top, @ex) = @$topic;
		@$topic = ();
		next unless defined $top;  # ghost topic
		my $mid = delete $seen->{$top};
		my $href = mid_escape($mid);
		$top = PublicInbox::Hval->new($top)->as_html;
		$ts = fmt_ts($ts);

		# $n isn't the total number of posts on the topic,
		# just the number of posts in the current results window
		my $anchor;
		if ($n == 1) {
			$n = '';
			$anchor = '#u'; # top of only message
		} else {
			$n = " ($n+ messages)";
			$anchor = '#t'; # thread skeleton
		}

		my $mbox = qq(<a\nhref="$href/t.mbox.gz">mbox.gz</a>);
		my $atom = qq(<a\nhref="$href/t.atom">Atom</a>);
		my $s = "<a\nhref=\"$href/T/$anchor\"><b>$top</b></a>\n" .
			" $ts UTC $n - $mbox / $atom\n";
		for (my $i = 0; $i < scalar(@ex); $i += 2) {
			my $level = $ex[$i];
			my $sub = $ex[$i + 1];
			$mid = delete $seen->{$sub};
			$sub = PublicInbox::Hval->new($sub)->as_html;
			$href = mid_escape($mid);
			$s .= indent_for($level) . TCHILD;
			$s .= "<a\nhref=\"$href/T/#u\">$sub</a>\n";
		}
		push @out, $s;
	}
	$ctx->{-html_tip} = '<pre>' . join("\n", @out) . '</pre>';
	200;
}

sub index_nav { # callback for WwwStream
	my (undef, $ctx) = @_;
	delete $ctx->{qp} or return;
	my ($next, $prev);
	$next = $prev = '    ';
	my $latest = '';

	my $next_o = $ctx->{-next_o};
	if ($next_o) {
		$next = qq!<a\nhref="?o=$next_o"\nrel=next>next</a>!;
	}
	if (my $cur_o = $ctx->{-cur_o}) {
		$latest = qq! <a\nhref=.>latest</a>!;

		my $o = $cur_o - ($next_o - $cur_o);
		if ($o > 0) {
			$prev = qq!<a\nhref="?o=$o"\nrel=prev>prev</a>!;
		} elsif ($o == 0) {
			$prev = qq!<a\nhref=.\nrel=prev>prev</a>!;
		}
	}
	"<hr><pre>page: $next $prev$latest</pre>";
}

sub index_topics {
	my ($ctx) = @_;
	my ($off) = (($ctx->{qp}->{o} || '0') =~ /(\d+)/);
	my $opts = { offset => $off, limit => 200 };

	$ctx->{order} = [];
	my $srch = $ctx->{srch};
	my $sres = $srch->query('', $opts);
	my $nr = scalar @{$sres->{msgs}};
	if ($nr) {
		$sres = load_results($srch, $sres);
		walk_thread(thread_results($sres), $ctx, *acc_topic);
	}
	$ctx->{-next_o} = $off+ $nr;
	$ctx->{-cur_o} = $off;
	PublicInbox::WwwStream->response($ctx, dump_topics($ctx), *index_nav);
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
	my ($ctx, $level, $node) = @_;
	my ($beg, $end) = thread_adj_level($ctx,  $level);
	$beg . '<pre>'. ghost_parent($ctx->{-upfx}, $node->{id})
		. '</pre>' . $end;
}

1;
