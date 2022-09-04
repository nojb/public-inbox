# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used for displaying the HTML web interface.
# See Documentation/design_www.txt for this.
package PublicInbox::View;
use strict;
use v5.10.1;
use List::Util qw(max);
use Text::Wrap qw(wrap); # stdlib, we need Perl 5.6+ for $huge
use PublicInbox::MsgTime qw(msg_datestamp);
use PublicInbox::Hval qw(ascii_html obfuscate_addrs prurl mid_href
			ts2str fmt_ts);
use PublicInbox::Linkify;
use PublicInbox::MID qw(id_compress mids mids_for_index references
			$MID_EXTRACT);
use PublicInbox::MsgIter;
use PublicInbox::Address;
use PublicInbox::WwwStream qw(html_oneshot);
use PublicInbox::Reply;
use PublicInbox::ViewDiff qw(flush_diff);
use PublicInbox::Eml;
use POSIX qw(strftime);
use Time::Local qw(timegm);
use PublicInbox::Smsg qw(subject_normalized);
use PublicInbox::ContentHash qw(content_hash);
use constant COLS => 72;
use constant INDENT => '  ';
use constant TCHILD => '` ';
sub th_pfx ($) { $_[0] == 0 ? '' : TCHILD };

sub msg_page_i {
	my ($ctx, $eml) = @_;
	if ($eml) { # called by WwwStream::async_eml or getline
		my $smsg = $ctx->{smsg};
		my $over = $ctx->{ibx}->over;
		$ctx->{smsg} = $over ? $over->next_by_mid(@{$ctx->{next_arg}})
				: $ctx->gone('over');
		$ctx->{mhref} = ($ctx->{nr} || $ctx->{smsg}) ?
				"../${\mid_href($smsg->{mid})}/" : '';
		my $obuf = _msg_page_prepare_obuf($eml, $ctx);
		if (length($$obuf)) {
			multipart_text_as_html($eml, $ctx);
			$$obuf .= '</pre><hr>';
		}
		delete $ctx->{obuf};
		$$obuf .= html_footer($ctx, $ctx->{first_hdr}) if !$ctx->{smsg};
		$$obuf;
	} else { # called by WwwStream::async_next or getline
		$ctx->{smsg}; # may be undef
	}
}

# /$INBOX/$MSGID/ for unindexed v1 inboxes
sub no_over_html ($) {
	my ($ctx) = @_;
	my $bref = $ctx->{ibx}->msg_by_mid($ctx->{mid}) or return; # 404
	my $eml = PublicInbox::Eml->new($bref);
	$ctx->{mhref} = '';
	PublicInbox::WwwStream::init($ctx);
	my $obuf = _msg_page_prepare_obuf($eml, $ctx);
	if (length($$obuf)) {
		multipart_text_as_html($eml, $ctx);
		$$obuf .= '</pre><hr>';
	}
	delete $ctx->{obuf};
	eval { $$obuf .= html_footer($ctx, $eml) };
	html_oneshot($ctx, 200, $$obuf);
}

# public functions: (unstable)

sub msg_page {
	my ($ctx) = @_;
	my $ibx = $ctx->{ibx};
	$ctx->{-obfs_ibx} = $ibx->{obfuscate} ? $ibx : undef;
	my $over = $ibx->over or return no_over_html($ctx);
	my ($id, $prev);
	my $next_arg = $ctx->{next_arg} = [ $ctx->{mid}, \$id, \$prev ];

	my $smsg = $ctx->{smsg} = $over->next_by_mid(@$next_arg) or
		return; # undef == 404

	# allow user to easily browse the range around this message if
	# they have ->over
	$ctx->{-t_max} = $smsg->{ts};
	PublicInbox::WwwStream::aresponse($ctx, 200, \&msg_page_i);
}

# /$INBOX/$MESSAGE_ID/#R
sub msg_reply ($$) {
	my ($ctx, $hdr) = @_;
	my $se_url =
	 'https://kernel.org/pub/software/scm/git/docs/git-send-email.html';
	my $p_url =
	 'https://en.wikipedia.org/wiki/Posting_style#Interleaved_style';

	my $info = '';
	my $ibx = $ctx->{ibx};
	if (my $url = $ibx->{infourl}) {
		$url = prurl($ctx->{env}, $url);
		$info = qq(\n  List information: <a\nhref="$url">$url</a>\n);
	}

	my ($arg, $link, $reply_to_all) =
			PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
	if (ref($arg) eq 'SCALAR') {
		return '<pre id=R>'.ascii_html($$arg).'</pre>';
	}

	# mailto: link only works if address obfuscation is disabled
	if ($link) {
		$link = <<EOF;

* If your mail client supports setting the <b>In-Reply-To</b> header
  via mailto: links, try the <a
href="$link">mailto: link</a>
EOF
	}

	push @$arg, '/path/to/YOUR_REPLY';
	$arg = ascii_html(join(" \\\n    ", '', @$arg));
	<<EOF
<hr><pre
id=R><b>Reply instructions:</b>

You may reply publicly to <a
href=#t>this message</a> via plain-text email
using any one of the following methods:

* Save the following mbox file, import it into your mail client,
  and $reply_to_all from there: <a
href=raw>mbox</a>

  Avoid top-posting and favor interleaved quoting:
  <a
href="$p_url">$p_url</a>
$info
* Reply using the <b>--to</b>, <b>--cc</b>, and <b>--in-reply-to</b>
  switches of git-send-email(1):

  git send-email$arg

  <a
href="$se_url">$se_url</a>
$link</pre>

  Be sure your reply has a <b>Subject:</b> header at the top and a blank line
  before the message body.
EOF
}

sub in_reply_to {
	my ($hdr) = @_;
	my $refs = references($hdr);
	$refs->[-1];
}

sub fold_addresses ($) {
	return $_[0] if length($_[0]) <= COLS;
	# try to fold on commas after non-word chars before $lim chars,
	# Try to get the "," preceded by ">" or ")", but avoid folding
	# on the comma where somebody uses "Lastname, Firstname".
	# We also try to keep the last and penultimate addresses in
	# the list on the same line if possible, hence the extra \z
	# Fall back to folding on spaces at $lim + 1 chars
	my $lim = COLS - 8; # 8 = "\t" display width
	my $too_long = $lim + 1;
	$_[0] =~ s/\s*\z//s; # Email::Simple doesn't strip trailing spaces
	$_[0] = join("\n\t",
		($_[0] =~ /(.{0,$lim}\W(?:,|\z)|
				.{1,$lim}(?:,|\z)|
				.{1,$lim}|
				.{$too_long,}?)(?:\s|\z)/xgo));
}

sub _hdr_names_html ($$) {
	my ($hdr, $field) = @_;
	my @vals = $hdr->header($field) or return '';
	ascii_html(join(', ', PublicInbox::Address::names(join(',', @vals))));
}

sub nr_to_s ($$$) {
	my ($nr, $singular, $plural) = @_;
	return "0 $plural" if $nr == 0;
	$nr == 1 ? "$nr $singular" : "$nr $plural";
}

# Displays the text of of the message for /$INBOX/$MSGID/[Tt]/ endpoint
# this is already inside a <pre>
sub eml_entry {
	my ($ctx, $eml) = @_;
	my $smsg = delete $ctx->{smsg};
	my $subj = delete $smsg->{subject};
	my $mid_raw = $smsg->{mid};
	my $id = id_compress($mid_raw, 1);
	my $id_m = 'm'.$id;
	my $root_anchor = $ctx->{root_anchor} || '';
	my $irt;
	my $obfs_ibx = $ctx->{-obfs_ibx};

	$subj = '(no subject)' if $subj eq '';
	my $rv = "<a\nhref=#e$id\nid=m$id>*</a> ";
	$subj = '<b>'.ascii_html($subj).'</b>';
	obfuscate_addrs($obfs_ibx, $subj) if $obfs_ibx;
	$subj = "<u\nid=u>$subj</u>" if $root_anchor eq $id_m;
	$rv .= $subj . "\n";
	$rv .= _th_index_lite($mid_raw, \$irt, $id, $ctx);
	my @tocc;
	my $ds = delete $smsg->{ds}; # for v1 non-Xapian/SQLite users

	# Deleting these fields saves about 400K as we iterate across 1K msgs
	delete @$smsg{qw(ts blob)};

	my $from = _hdr_names_html($eml, 'From');
	obfuscate_addrs($obfs_ibx, $from) if $obfs_ibx;
	$rv .= "From: $from @ ".fmt_ts($ds)." UTC";
	my $upfx = $ctx->{-upfx};
	my $mhref = $upfx . mid_href($mid_raw) . '/';
	$rv .= qq{ (<a\nhref="$mhref">permalink</a> / };
	$rv .= qq{<a\nhref="${mhref}raw">raw</a>)\n};
	my $to = fold_addresses(_hdr_names_html($eml, 'To'));
	my $cc = fold_addresses(_hdr_names_html($eml, 'Cc'));
	my ($tlen, $clen) = (length($to), length($cc));
	my $to_cc = '';
	if (($tlen + $clen) > COLS) {
		$to_cc .= '  To: '.$to."\n" if $tlen;
		$to_cc .= '  Cc: '.$cc."\n" if $clen;
	} else {
		if ($tlen) {
			$to_cc .= '  To: '.$to;
			$to_cc .= '; <b>+Cc:</b> '.$cc if $clen;
		} else {
			$to_cc .= '  Cc: '.$cc if $clen;
		}
		$to_cc .= "\n";
	}
	obfuscate_addrs($obfs_ibx, $to_cc) if $obfs_ibx;
	$rv .= $to_cc;

	my $mapping = $ctx->{mapping};
	if (!$mapping && (defined($irt) || defined($irt = in_reply_to($eml)))) {
		my $href = $upfx . mid_href($irt) . '/';
		my $html = ascii_html($irt);
		$rv .= qq(In-Reply-To: &lt;<a\nhref="$href">$html</a>&gt;\n)
	}
	$rv .= "\n";

	# scan through all parts, looking for displayable text
	$ctx->{mhref} = $mhref;
	$ctx->{changed_href} = "#e$id"; # for diffstat "files? changed,"
	$ctx->{obuf} = \$rv;
	$eml->each_part(\&add_text_body, $ctx, 1);
	delete $ctx->{obuf};

	# add the footer
	$rv .= "\n<a\nhref=#$id_m\nid=e$id>^</a> ".
		"<a\nhref=\"$mhref\">permalink</a>" .
		" <a\nhref=\"${mhref}raw\">raw</a>" .
		" <a\nhref=\"${mhref}#R\">reply</a>";

	delete($ctx->{-qry}) and
		$rv .= qq[ <a\nhref="${mhref}#related">related</a>];

	my $hr;
	if (defined(my $pct = $smsg->{pct})) { # used by SearchView.pm
		$rv .= "\t[relevance $pct%]";
		$hr = 1;
	} elsif ($mapping) {
		my $nested = 'nested';
		my $flat = 'flat';
		if ($ctx->{flat}) {
			$hr = 1;
			$flat = "<b>$flat</b>";
		} else {
			$nested = "<b>$nested</b>";
		}
		$rv .= "\t[<a\nhref=\"${mhref}T/#u\">$flat</a>";
		$rv .= "|<a\nhref=\"${mhref}t/#u\">$nested</a>]";
		$rv .= " <a\nhref=#r$id>$ctx->{s_nr}</a>";
	} else {
		$hr = $ctx->{-hr};
	}

	# do we have more messages? start a new <pre> if so
	$rv .= scalar(@{$ctx->{msgs}}) ? '</pre><hr><pre>' : '</pre>' if $hr;
	$rv;
}

sub pad_link ($$;$) {
	my ($mid, $level, $s) = @_;
	$s ||= '...';
	my $href = defined($mid) ?
		("<a\nhref=#r".id_compress($mid, 1).">($s)</a>\n") :
		"($s)\n";
	(' 'x19).indent_for($level).th_pfx($level).$href;
}

sub _skel_hdr {
	# my ($mapping, $mid) = @_;
	($_[0]->{$_[1] // \'bogus'} // [ "(?)\n" ])->[0];
}

sub _th_index_lite {
	my ($mid_raw, $irt, $id, $ctx) = @_;
	my $rv = '';
	my $mapping = $ctx->{mapping} or return $rv;
	my $pad = '  ';
	my $mid_map = $mapping->{$mid_raw};
	defined $mid_map or
		return 'public-inbox BUG: '.ascii_html($mid_raw).' not mapped';
	my ($attr, $node, $idx, $level) = @$mid_map;
	my $children = $node->{children};
	my $nr_c = scalar @$children;
	my $nr_s = 0;
	my $siblings;
	# delete saves about 200KB on a 1K message thread
	if (my $refs = delete $node->{references}) {
		($$irt) = ($refs =~ m/$MID_EXTRACT\z/o);
	}
	my $irt_map = $mapping->{$$irt} if defined $$irt;
	if (defined $irt_map) {
		$siblings = $irt_map->[1]->{children};
		$nr_s = scalar(@$siblings) - 1;
		$rv .= $pad . $irt_map->[0];
		if ($idx > 0) {
			my $prev = $siblings->[$idx - 1];
			my $pmid = $prev->{mid};
			if ($idx > 2) {
				my $s = ($idx - 1). ' preceding siblings ...';
				$rv .= pad_link($pmid, $level, $s);
			} elsif ($idx == 2) {
				$rv .= $pad . _skel_hdr($mapping,
						$siblings->[0] ?
						$siblings->[0]->{mid} : undef);
			}
			$rv .= $pad . _skel_hdr($mapping, $pmid);
		}
	}
	my $s_s = nr_to_s($nr_s, 'sibling', 'siblings');
	my $s_c = nr_to_s($nr_c, 'reply', 'replies');
	$attr =~ s!\n\z!</b>\n!s;
	$attr =~ s!<a\nhref.*</a> (?:&#34; )?!!s; # no point in dup subject
	$attr =~ s!<a\nhref=[^>]+>([^<]+)</a>!$1!s; # no point linking to self
	$rv .= "<b>@ $attr";
	if ($nr_c) {
		my $cmid = $children->[0] ? $children->[0]->{mid} : undef;
		$rv .= $pad . _skel_hdr($mapping, $cmid);
		if ($nr_c > 2) {
			my $s = ($nr_c - 1). ' more replies';
			$rv .= pad_link($cmid, $level + 1, $s);
		} elsif (my $cn = $children->[1]) {
			$rv .= $pad . _skel_hdr($mapping, $cn->{mid});
		}
	}

	my $next = $siblings->[$idx+1] if $siblings && $idx >= 0;
	if ($next) {
		my $nmid = $next->{mid};
		$rv .= $pad . _skel_hdr($mapping, $nmid);
		my $nnext = $nr_s - $idx;
		if ($nnext > 2) {
			my $s = ($nnext - 1).' subsequent siblings';
			$rv .= pad_link($nmid, $level, $s);
		} elsif (my $nn = $siblings->[$idx + 2]) {
			$rv .= $pad . _skel_hdr($mapping, $nn->{mid});
		}
	}
	$rv .= $pad ."<a\nhref=#r$id>$s_s, $s_c; $ctx->{s_nr}</a>\n";
}

# non-recursive thread walker
sub walk_thread ($$$) {
	my ($rootset, $ctx, $cb) = @_;
	my @q = map { (0, $_, -1) } @$rootset;
	while (@q) {
		my ($level, $node, $i) = splice(@q, 0, 3);
		defined $node or next;
		$cb->($ctx, $level, $node, $i) or return;
		++$level;
		$i = 0;
		unshift @q, map { ($level, $_, $i++) } @{$node->{children}};
	}
}

sub pre_thread  { # walk_thread callback
	my ($ctx, $level, $node, $idx) = @_;
	$ctx->{mapping}->{$node->{mid}} = [ '', $node, $idx, $level ];
	skel_dump($ctx, $level, $node);
}

sub thread_eml_entry {
	my ($ctx, $eml) = @_;
	my ($beg, $end) = thread_adj_level($ctx, $ctx->{level});
	$beg . '<pre>' . eml_entry($ctx, $eml) . '</pre>' . $end;
}

sub next_in_queue ($$) {
	my ($q, $ghost_ok) = @_;
	while (@$q) {
		my ($level, $smsg) = splice(@$q, 0, 2);
		my $cl = $level + 1;
		unshift @$q, map { ($cl, $_) } @{$smsg->{children}};
		return ($level, $smsg) if $ghost_ok || exists($smsg->{blob});
	}
	undef;
}

sub stream_thread_i { # PublicInbox::WwwStream::getline callback
	my ($ctx, $eml) = @_;
	return thread_eml_entry($ctx, $eml) if $eml;
	return unless exists($ctx->{skel});
	my $ghost_ok = $ctx->{nr}++;
	while (1) {
		my ($lvl, $smsg) = next_in_queue($ctx->{-queue}, $ghost_ok);
		if ($smsg) {
			if (exists $smsg->{blob}) { # next message for cat-file
				$ctx->{level} = $lvl;
				if (!$ghost_ok) { # first non-ghost
					$ctx->{-title_html} =
						ascii_html($smsg->{subject});
					$ctx->zmore($ctx->html_top);
				}
				return $smsg;
			}
			# buffer the ghost entry and loop
			$ctx->zmore(ghost_index_entry($ctx, $lvl, $smsg));
		} else { # all done
			$ctx->zmore(join('', thread_adj_level($ctx, 0)));
			$ctx->zmore(${delete($ctx->{skel})});
			return;
		}
	}
}

sub stream_thread ($$) {
	my ($rootset, $ctx) = @_;
	@{$ctx->{-queue}} = map { (0, $_) } @$rootset;
	PublicInbox::WwwStream::aresponse($ctx, 200, \&stream_thread_i);
}

# /$INBOX/$MSGID/t/ and /$INBOX/$MSGID/T/
sub thread_html {
	my ($ctx) = @_;
	$ctx->{-upfx} = '../../';
	my $mid = $ctx->{mid};
	my $ibx = $ctx->{ibx};
	my ($nr, $msgs) = $ibx->over->get_thread($mid);
	return missing_thread($ctx) if $nr == 0;

	# link $INBOX_DIR/description text to "index_topics" view around
	# the newest message in this thread
	my $t = ts2str($ctx->{-t_max} = max(map { delete $_->{ts} } @$msgs));
	my $t_fmt = fmt_ts($ctx->{-t_max});

	my $skel = '<hr><pre>';
	$skel .= $nr == 1 ? 'only message in thread' : 'end of thread';
	$skel .= <<EOF;
, other threads:[<a
href="../../?t=$t">~$t_fmt UTC</a> | <a
href="../../">newest</a>]

EOF
	$skel .= "<b\nid=t>Thread overview:</b> ";
	$skel .= $nr == 1 ? '(only message)' : "$nr+ messages";
	$skel .= " (download: <a\nhref=\"../t.mbox.gz\">mbox.gz</a>";
	$skel .= " / follow: <a\nhref=\"../t.atom\">Atom feed</a>)\n";
	$skel .= "-- links below jump to the message on this page --\n";
	$ctx->{cur_level} = 0;
	$ctx->{skel} = \$skel;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{root_anchor} = 'm' . id_compress($mid, 1);
	$ctx->{mapping} = {}; # mid -> [ header_summary, node, idx, level ]
	$ctx->{s_nr} = ($nr > 1 ? "$nr+ messages" : 'only message')
	               .' in thread';

	my $rootset = thread_results($ctx, $msgs);

	# reduce hash lookups in pre_thread->skel_dump
	$ctx->{-obfs_ibx} = $ibx->{obfuscate} ? $ibx : undef;
	walk_thread($rootset, $ctx, \&pre_thread);

	$skel .= '</pre>';
	return stream_thread($rootset, $ctx) unless $ctx->{flat};

	# flat display: lazy load the full message from smsg
	$ctx->{msgs} = $msgs;
	$ctx->{-html_tip} = '<pre>';
	PublicInbox::WwwStream::aresponse($ctx, 200, \&thread_html_i);
}

sub thread_html_i { # PublicInbox::WwwStream::getline callback
	my ($ctx, $eml) = @_;
	if ($eml) {
		my $smsg = $ctx->{smsg};
		if (exists $ctx->{-html_tip}) {
			$ctx->{-title_html} = ascii_html($smsg->{subject});
			$ctx->zmore($ctx->html_top);
		}
		return eml_entry($ctx, $eml);
	} else {
		while (my $smsg = shift @{$ctx->{msgs}}) {
			return $smsg if exists($smsg->{blob});
		}
		my $skel = delete($ctx->{skel}) or return; # all done
		$ctx->zmore($$skel);
		undef;
	}
}

sub multipart_text_as_html {
	# ($mime, $ctx) = @_; # each_part may do "$_[0] = undef"

	# scan through all parts, looking for displayable text
	$_[0]->each_part(\&add_text_body, $_[1], 1);
}

sub submsg_hdr ($$) {
	my ($ctx, $eml) = @_;
	my $obfs_ibx = $ctx->{-obfs_ibx};
	my $rv = $ctx->{obuf};
	$$rv .= "\n";
	for my $h (qw(From To Cc Subject Date Message-ID X-Alt-Message-ID)) {
		my @v = $eml->header($h);
		for my $v (@v) {
			obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx;
			$v = ascii_html($v);
			$$rv .= "$h: $v\n";
		}
	}
}

sub attach_link ($$$$;$) {
	my ($ctx, $ct, $p, $fn, $err) = @_;
	my ($part, $depth, $idx) = @$p;

	# Eml iteration clobbers multipart ->{bdy}, so do not offer
	# downloads for 0-byte multipart attachments
	return unless $part->{bdy};

	my $nl = $idx eq '1' ? '' : "\n"; # like join("\n", ...)
	my $size = length($part->body);
	delete $part->{bdy}; # save memory

	# hide attributes normally, unless we want to aid users in
	# spotting MUA problems:
	$ct =~ s/;.*// unless $err;
	$ct = ascii_html($ct);
	my $sfn;
	if (defined $fn && $fn =~ /\A$PublicInbox::Hval::FN\z/o) {
		$sfn = $fn;
	} elsif ($ct eq 'text/plain') {
		$sfn = 'a.txt';
	} else {
		$sfn = 'a.bin';
	}
	my $rv = $ctx->{obuf};
	$$rv .= qq($nl<a\nhref="$ctx->{mhref}$idx-$sfn">);
	if ($err) {
		$$rv .= <<EOF;
[-- Warning: decoded text below may be mangled, UTF-8 assumed --]
EOF
	}
	$$rv .= "[-- Attachment #$idx: ";
	my $ts = "Type: $ct, Size: $size bytes";
	my $desc = $part->header('Content-Description') // $fn // '';
	$desc = ascii_html($desc);
	$$rv .= ($desc eq '') ? "$ts --]" : "$desc --]\n[-- $ts --]";
	$$rv .= "</a>\n";

	submsg_hdr($ctx, $part) if $part->{is_submsg};

	undef;
}

sub add_text_body { # callback for each_part
	my ($p, $ctx) = @_;
	my $upfx = $ctx->{mhref};
	my $ibx = $ctx->{ibx};
	my $l = $ctx->{-linkify} //= PublicInbox::Linkify->new;
	# $p - from each_part: [ Email::MIME-like, depth, $idx ]
	my ($part, $depth, $idx) = @$p;
	my $ct = $part->content_type || 'text/plain';
	my $fn = $part->filename;
	my ($s, $err) = msg_part_text($part, $ct);
	return attach_link($ctx, $ct, $p, $fn) unless defined $s;

	my $rv = $ctx->{obuf};
	if ($part->{is_submsg}) {
		submsg_hdr($ctx, $part);
		$$rv .= "\n";
	}

	# makes no difference to browsers, and don't screw up filename
	# link generation in diffs with the extra '%0D'
	$s =~ s/\r+\n/\n/sg;

	# will be escaped to `&#8226;' in HTML
	obfuscate_addrs($ibx, $s, "\x{2022}") if $ibx->{obfuscate};

	# always support diff-highlighting, but we can't linkify hunk
	# headers for solver unless some coderepo are configured:
	my $diff;
	if ($s =~ /^--- [^\n]+\n\+{3} [^\n]+\n@@ /ms) {
		# diffstat anchors do not link across attachments or messages,
		# -apfx is just a stable prefix for making diffstat anchors
		# linkable to the first diff hunk w/o crossing attachments
		$idx =~ tr!.!/!; # compatibility with previous versions
		$ctx->{-apfx} = $upfx . $idx;

		# do attr => filename mappings for diffstats in git diffs:
		$ctx->{-anchors} = {} if $s =~ /^diff --git /sm;
		$diff = 1;
		delete $ctx->{-long_path};
		my $spfx;
		# absolute URL (Atom feeds)
		if ($ibx->{coderepo}) {
			if (index($upfx, '//') >= 0) {
				$spfx = $upfx;
				$spfx =~ s!/([^/]*)/\z!/!;
			} else {
				my $n_slash = $upfx =~ tr!/!/!;
				if ($n_slash == 0) {
					$spfx = '../';
				} elsif ($n_slash == 1) {
					$spfx = '';
				} else { # nslash == 2
					$spfx = '../../';
				}
			}
		}
		$ctx->{-spfx} = $spfx;
	};

	# split off quoted and unquoted blocks:
	my @sections = PublicInbox::MsgIter::split_quotes($s);
	undef $s; # free memory
	if (defined($fn) || ($depth > 0 && !$part->{is_submsg}) || $err) {
		# badly-encoded message with $err? tell the world about it!
		attach_link($ctx, $ct, $p, $fn, $err);
		$$rv .= "\n";
	}
	delete $part->{bdy}; # save memory
	foreach my $cur (@sections) {
		if ($cur =~ /\A>/) {
			# we use a <span> here to allow users to specify
			# their own color for quoted text
			$$rv .= qq(<span\nclass="q">);
			$$rv .= $l->to_html($cur);
			$$rv .= '</span>';
		} elsif ($diff) {
			flush_diff($ctx, \$cur);
		} else {
			# regular lines, OK
			$$rv .= $l->to_html($cur);
		}
		undef $cur; # free memory
	}
}

sub _msg_page_prepare_obuf {
	my ($eml, $ctx) = @_;
	my $have_over = !!$ctx->{ibx}->over;
	my $obfs_ibx = $ctx->{-obfs_ibx};
	$ctx->{obuf} = \(my $rv = '');
	my $mids = mids_for_index($eml);
	my $nr = $ctx->{nr}++;
	if ($nr) { # unlikely
		if ($ctx->{chash} eq content_hash($eml)) {
			warn "W: BUG? @$mids not deduplicated properly\n";
			return \$rv;
		}
		$rv .=
"<pre>WARNING: multiple messages have this Message-ID\n</pre><pre>";
	} else {
		$ctx->{first_hdr} = $eml->header_obj;
		$ctx->{chash} = content_hash($eml) if $ctx->{smsg}; # reused MID
		$rv .= "<pre\nid=b>"; # anchor for body start
	}
	$ctx->{-upfx} = '../';
	my @title; # (Subject[0], From[0])
	for my $v ($eml->header('From')) {
		my @n = PublicInbox::Address::names($v);
		$v = ascii_html($v);
		$title[1] //= ascii_html(join(', ', @n));
		if ($obfs_ibx) {
			obfuscate_addrs($obfs_ibx, $v);
			obfuscate_addrs($obfs_ibx, $title[1]);
		}
		$rv .= "From: $v\n" if $v ne '';
	}
	foreach my $h (qw(To Cc)) {
		for my $v ($eml->header($h)) {
			fold_addresses($v);
			$v = ascii_html($v);
			obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx;
			$rv .= "$h: $v\n" if $v ne '';
		}
	}
	my @subj = $eml->header('Subject');
	if (@subj) {
		my $v = ascii_html(shift @subj);
		obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx;
		$rv .= 'Subject: ';
		$rv .= $have_over ? qq(<a\nhref="#r"\nid=t>$v</a>\n) : "$v\n";
		$title[0] = $v;
		for $v (@subj) { # multi-Subject message :<
			$v = ascii_html($v);
			obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx;
			$rv .= "Subject: $v\n";
		}
	} else { # dummy anchor for thread skeleton at bottom of page
		$rv .= qq(<a\nhref="#r"\nid=t></a>) if $have_over;
		$title[0] = '(no subject)';
	}
	for my $v ($eml->header('Date')) {
		$v = ascii_html($v);
		obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx; # possible :P
		$rv .= qq{Date: $v\n};
	}
	# [thread overview] link is typically added after Date,
	# but added after Subject, or even nothing.
	if ($have_over) {
		chop $rv; # drop "\n", or noop if $rv eq ''
		$rv .= qq{\t<a\nhref="#r">[thread overview]</a>\n};
	}
	if (!$nr) { # first (and only) message, common case
		$ctx->{-title_html} = join(' - ', @title);
		$rv = $ctx->html_top . $rv;
	}

	$ctx->{-linkify} //= PublicInbox::Linkify->new;
	if (scalar(@$mids) == 1) { # common case
		my $mhtml = ascii_html($mids->[0]);
		$rv .= qq[Message-ID: &lt;$mhtml&gt; (<a href="raw">raw</a>)\n];
	} else {
		# X-Alt-Message-ID can happen if a message is injected from
		# public-inbox-nntpd because of multiple Message-ID headers.
		my $s = '';
		for my $h (qw(Message-ID X-Alt-Message-ID)) {
			$s .= "$h: $_\n" for ($eml->header_raw($h));
		}
		$ctx->{-linkify}->linkify_mids('..', \$s, 1);
		$rv .= $s;
	}
	_parent_headers($ctx, $eml);
	$rv .= "\n";
	\$rv;
}

sub SKEL_EXPAND () {
	qq(expand[<a\nhref="T/#u">flat</a>) .
		qq(|<a\nhref="t/#u">nested</a>]  ) .
		qq(<a\nhref="t.mbox.gz">mbox.gz</a>  ) .
		qq(<a\nhref="t.atom">Atom feed</a>);
}

sub thread_skel ($$$) {
	my ($skel, $ctx, $hdr) = @_;
	my $mid = mids($hdr)->[0];
	my $ibx = $ctx->{ibx};
	my ($nr, $msgs) = $ibx->over->get_thread($mid);
	my $parent = in_reply_to($hdr);
	$$skel .= "\n<b>Thread overview: </b>";
	if ($nr <= 1) {
		if (defined $parent) {
			$$skel .= SKEL_EXPAND."\n ";
			$$skel .= ghost_parent('../', $parent) . "\n";
		} else {
			$$skel .= "<a\nid=r>[no followups]</a> ".
					SKEL_EXPAND."\n";
		}
		$ctx->{next_msg} = undef;
		$ctx->{parent_msg} = $parent;
		return;
	}

	$$skel .= $nr;
	$$skel .= '+ messages / '.SKEL_EXPAND.qq!  <a\nhref="#b">top</a>\n!;

	# nb: mutt only shows the first Subject in the index pane
	# when multiple Subject: headers are present, so we follow suit:
	my $subj = $hdr->header('Subject') // '';
	$subj = '(no subject)' if $subj eq '';
	$ctx->{cur} = $mid;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{skel} = $skel;

	# reduce hash lookups in skel_dump
	$ctx->{-obfs_ibx} = $ibx->{obfuscate} ? $ibx : undef;
	walk_thread(thread_results($ctx, $msgs), $ctx, \&skel_dump);

	$ctx->{parent_msg} = $parent;
}

sub _parent_headers {
	my ($ctx, $hdr) = @_;
	my @irt = $hdr->header_raw('In-Reply-To');
	my $refs;
	if (@irt) {
		my $s = '';
		$s .= "In-Reply-To: $_\n" for @irt;
		$ctx->{-linkify}->linkify_mids('..', \$s);
		${$ctx->{obuf}} .= $s;
	} else {
		$refs = references($hdr);
		my $irt = pop @$refs;
		if (defined $irt) {
			my $html = ascii_html($irt);
			my $href = mid_href($irt);
			${$ctx->{obuf}} .= <<EOM;
In-Reply-To: &lt;<a\nhref="../$href/">$html</a>&gt;
EOM
		}
	}

	# do not display References: if search is present,
	# we show the thread skeleton at the bottom, instead.
	return if $ctx->{ibx}->over;

	$refs //= references($hdr);
	if (@$refs) {
		$_ = linkify_ref_no_over($_) for @$refs;
		${$ctx->{obuf}} .= 'References: '. join("\n\t", @$refs) . "\n";
	}
}

# returns a string buffer
sub html_footer {
	my ($ctx, $hdr) = @_;
	my $upfx = '../';
	my $skel;
	my $rv = '<pre>';
	my $related;
	my $qry = delete $ctx->{-qry};
	if ($qry && $ctx->{ibx}->isrch) {
		my $q = ''; # search for either ancestor or descendent patches
		for (@{$qry->{dfpre}}, @{$qry->{dfpost}}) {
			chop if length > 7; # include 1 abbrev "older" patches
			$q .= "dfblob:$_ ";
		}
		chop $q; # omit trailing SP
		local $Text::Wrap::columns = COLS;
		local $Text::Wrap::huge = 'overflow';
		$q = wrap('', '', $q);
		my $rows = ($q =~ tr/\n/\n/) + 1;
		$q = ascii_html($q);
		$related = <<EOM;
<form id=related
action=$upfx
><pre>find likely ancestor, descendant, or conflicting patches for <a
href=#t>this message</a>:
<textarea name=q cols=${\COLS} rows=$rows>$q</textarea>
<input type=submit value=search
/>\t(<a href=${upfx}_/text/help/#search>help</a>)</pre></form>
EOM
	}
	if ($ctx->{ibx}->over) {
		my $t = ts2str($ctx->{-t_max});
		my $t_fmt = fmt_ts($ctx->{-t_max});
		my $fallback = $related ? "\t" : "<a id=related>\t</a>";
		$skel = <<EOF;
${fallback}other threads:[<a
href="$upfx?t=$t">~$t_fmt UTC</a>|<a
href="$upfx">newest</a>]
EOF

		thread_skel(\$skel, $ctx, $hdr);
		my ($next, $prev);
		my $parent = '       ';
		$next = $prev = '    ';

		if (my $n = $ctx->{next_msg}) {
			$n = mid_href($n);
			$next = "<a\nhref=\"$upfx$n/\"\nrel=next>next</a>";
		}
		my $u;
		my $par = $ctx->{parent_msg};
		if ($par) {
			$u = mid_href($par);
			$u = "$upfx$u/";
		}
		if (my $p = $ctx->{prev_msg}) {
			$prev = mid_href($p);
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
		$rv .= "$next $prev$parent ";
	} else { # unindexed inboxes w/o over
		$skel = qq( <a\nhref="$upfx">latest</a>);
	}
	$rv .= qq(<a\nhref="#R">reply</a>);
	$rv .= $skel;
	$rv .= '</pre>';
	$rv .= $related // '';
	$rv .= msg_reply($ctx, $hdr);
}

sub linkify_ref_no_over {
	my ($mid) = @_;
	my $href = mid_href($mid);
	my $html = ascii_html($mid);
	"&lt;<a\nhref=\"../$href/\">$html</a>&gt;";
}

sub ghost_parent {
	my ($upfx, $mid) = @_;

	my $href = mid_href($mid);
	my $html = ascii_html($mid);
	qq{[parent not found: &lt;<a\nhref="$upfx$href/">$html</a>&gt;]};
}

sub indent_for {
	my ($level) = @_;
	$level ? INDENT x ($level - 1) : '';
}

sub find_mid_root {
	my ($ctx, $level, $node, $idx) = @_;
	++$ctx->{root_idx} if $level == 0;
	if ($node->{mid} eq $ctx->{mid}) {
		$ctx->{found_mid_at} = $ctx->{root_idx};
		return 0; # stop iterating
	}
	1;
}

sub strict_loose_note ($) {
	my ($nr) = @_;
	my $msg =
"  -- strict thread matches above, loose matches on Subject: below --\n";

	if ($nr > PublicInbox::Over::DEFAULT_LIMIT()) {
		$msg .=
"  -- use mbox.gz link to download all $nr messages --\n";
	}
	$msg;
}

sub thread_results {
	my ($ctx, $msgs) = @_;
	require PublicInbox::SearchThread;
	my $rootset = PublicInbox::SearchThread::thread($msgs, \&sort_ds, $ctx);

	# FIXME: `tid' is broken on --reindex, so that needs to be fixed
	# and preserved in the future.  This bug is hidden by `sid' matches
	# in get_thread, so we never noticed it until now.  And even when
	# reindexing is fixed, we'll keep this code until a SCHEMA_VERSION
	# bump since reindexing is expensive and users may not do it

	# loose threading could've returned too many results,
	# put the root the message we care about at the top:
	my $mid = $ctx->{mid};
	if (defined($mid) && scalar(@$rootset) > 1) {
		$ctx->{root_idx} = -1;
		my $nr = scalar @$msgs;
		walk_thread($rootset, $ctx, \&find_mid_root);
		my $idx = $ctx->{found_mid_at};
		if (defined($idx) && $idx != 0) {
			my $tip = splice(@$rootset, $idx, 1);
			@$rootset = reverse @$rootset;
			unshift @$rootset, $tip;
			$ctx->{sl_note} = strict_loose_note($nr);
		}
	}
	$rootset
}

sub missing_thread {
	my ($ctx) = @_;
	require PublicInbox::ExtMsg;
	PublicInbox::ExtMsg::ext_msg($ctx);
}

sub dedupe_subject {
	my ($prev_subj, $subj, $val) = @_;

	my $omit; # '"' denotes identical text omitted
	my (@prev_pop, @curr_pop);
	while (@$prev_subj && @$subj && $subj->[-1] eq $prev_subj->[-1]) {
		push(@prev_pop, pop(@$prev_subj));
		push(@curr_pop, pop(@$subj));
		$omit //= $val;
	}
	pop @$subj if @$subj && $subj->[-1] =~ /^re:\s*/i;
	if (scalar(@curr_pop) == 1) {
		$omit = undef;
		push @$prev_subj, @prev_pop;
		push @$subj, @curr_pop;
	}
	$omit // '';
}

sub skel_dump { # walk_thread callback
	my ($ctx, $level, $smsg) = @_;
	$smsg->{blob} or return _skel_ghost($ctx, $level, $smsg);

	my $skel = $ctx->{skel};
	my $cur = $ctx->{cur};
	my $mid = $smsg->{mid};

	if ($level == 0 && $ctx->{skel_dump_roots}++) {
		$$skel .= delete($ctx->{sl_note}) || '';
	}

	my $f = ascii_html(delete $smsg->{from_name});
	my $obfs_ibx = $ctx->{-obfs_ibx};
	obfuscate_addrs($obfs_ibx, $f) if $obfs_ibx;

	my $d = fmt_ts($smsg->{ds});
	my $unmatched; # if lazy-loaded by SearchThread::Msg::visible()
	if (exists $ctx->{searchview}) {
		if (defined(my $pct = $smsg->{pct})) {
			$d .= (sprintf(' % 2u', $pct) . '%');
		} else {
			$unmatched = 1;
			$d .= '    ';
		}
	}
	$d .= ' ' . indent_for($level) . th_pfx($level);
	my $attr = $f;
	$ctx->{first_level} ||= $level;

	if ($attr ne $ctx->{prev_attr} || $ctx->{prev_level} > $level) {
		$ctx->{prev_attr} = $attr;
	}
	$ctx->{prev_level} = $level;

	if ($cur) {
		if ($cur eq $mid) {
			delete $ctx->{cur};
			$$skel .= "<b>$d<a\nid=r\nhref=\"#t\">".
				 "$attr [this message]</a></b>\n";
			return 1;
		} else {
			$ctx->{prev_msg} = $mid;
		}
	} else {
		$ctx->{next_msg} ||= $mid;
	}

	# Subject is never undef, this mail was loaded from
	# our Xapian which would've resulted in '' if it were
	# really missing (and Filter rejects empty subjects)
	my @subj = split(/ /, subject_normalized($smsg->{subject}));
	# remove common suffixes from the subject if it matches the previous,
	# so we do not show redundant text at the end.
	my $prev_subj = $ctx->{prev_subj} || [];
	$ctx->{prev_subj} = [ @subj ];
	my $omit = dedupe_subject($prev_subj, \@subj, '&#34; ');
	my $end;
	if (@subj) {
		my $subj = join(' ', @subj);
		$subj = ascii_html($subj);
		obfuscate_addrs($obfs_ibx, $subj) if $obfs_ibx;
		$end = "$subj</a> $omit$f\n"
	} else {
		$end = "$f</a>\n";
	}
	my $m;
	my $id = '';
	my $mapping = $unmatched ? undef : $ctx->{mapping};
	if ($mapping) {
		my $map = $mapping->{$mid};
		$id = id_compress($mid, 1);
		$m = '#m'.$id;
		$map->[0] = "$d<a\nhref=\"$m\">$end";
		$id = "\nid=r".$id;
	} else {
		$m = $ctx->{-upfx}.mid_href($mid).'/';
	}
	$$skel .=  $d . "<a\nhref=\"$m\"$id>" . $end;
	1;
}

sub _skel_ghost {
	my ($ctx, $level, $node) = @_;

	my $mid = $node->{mid};
	my $d = '     [not found] ';
	$d .= '    '  if exists $ctx->{searchview};
	$d .= indent_for($level) . th_pfx($level);
	my $upfx = $ctx->{-upfx};
	my $href = $upfx . mid_href($mid) . '/';
	my $html = ascii_html($mid);

	my $mapping = $ctx->{mapping};
	my $map = $mapping->{$mid} if $mapping;
	if ($map) {
		my $id = id_compress($mid, 1);
		$map->[0] = $d . qq{&lt;<a\nhref=#r$id>$html</a>&gt;\n};
		$d .= qq{&lt;<a\nhref="$href"\nid=r$id>$html</a>&gt;\n};
	} else {
		$d .= qq{&lt;<a\nhref="$href">$html</a>&gt;\n};
	}
	${$ctx->{skel}} .= $d;
	1;
}

sub sort_ds {
	@{$_[0]} = sort {
		(eval { $a->topmost->{ds} } || 0) <=>
		(eval { $b->topmost->{ds} } || 0)
	} @{$_[0]};
}

# accumulate recent topics if search is supported
# returns 200 if done, 404 if not
sub acc_topic { # walk_thread callback
	my ($ctx, $level, $smsg) = @_;
	my $mid = $smsg->{mid};
	my $has_blob = $smsg->{blob} // do {
		if (my $by_mid = $ctx->{ibx}->smsg_by_mid($mid)) {
			%$smsg = (%$smsg, %$by_mid);
			1;
		}
	};
	if ($has_blob) {
		my $subj = subject_normalized($smsg->{subject});
		$subj = '(no subject)' if $subj eq '';
		my $ds = $smsg->{ds};
		if ($level == 0) { # new, top-level topic
			my $topic = [ $ds, 1, { $subj => $mid }, $subj ];
			$ctx->{-cur_topic} = $topic;
			push @{$ctx->{order}}, $topic;
			return 1;
		}

		# continue existing topic
		my $topic = $ctx->{-cur_topic}; # should never be undef
		$topic->[0] = $ds if $ds > $topic->[0];
		$topic->[1]++; # bump N+ message counter
		my $seen = $topic->[2];
		if (scalar(@$topic) == 3) { # parent was a ghost
			push @$topic, $subj;
		} elsif (!defined($seen->{$subj})) {
			push @$topic, $level, $subj; # @extra messages
		}
		$seen->{$subj} = $mid; # latest for subject
	} else { # ghost message
		return 1 if $level != 0; # ignore child ghosts
		my $topic = $ctx->{-cur_topic} = [ -666, 0, {} ];
		push @{$ctx->{order}}, $topic;
	}
	1;
}

sub dump_topics {
	my ($ctx) = @_;
	my $order = delete $ctx->{order}; # [ ds, subj1, subj2, subj3, ... ]
	unless ($order) {
		$ctx->{-html_tip} = '<pre>[No topics in range]</pre>';
		return 404;
	}

	my @out;
	my $obfs_ibx = $ctx->{ibx}->{obfuscate} ? $ctx->{ibx} : undef;
	if (my $note = delete $ctx->{t_note}) {
		push @out, $note; # "messages from ... to ..."
	}
	# sort by recency, this allows new posts to "bump" old topics...
	foreach my $topic (sort { $b->[0] <=> $a->[0] } @$order) {
		my ($ds, $n, $seen, $top_subj, @extra) = @$topic;
		@$topic = ();
		next unless defined $top_subj;  # ghost topic
		my $mid = delete $seen->{$top_subj};
		my $href = mid_href($mid);
		my $prev_subj = [ split(/ /, $top_subj) ];
		$top_subj = ascii_html($top_subj);
		$ds = fmt_ts($ds);

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

		my $s = "<a\nhref=\"$href/T/$anchor\">$top_subj</a>\n" .
			" $ds UTC $n\n";
		while (@extra) {
			my $level = shift @extra;
			my $subj = shift @extra; # already normalized
			$mid = delete $seen->{$subj};
			my @subj = split(/ /, $subj);
			my @next_prev = @subj; # full copy
			my $omit = dedupe_subject($prev_subj, \@subj, ' &#34;');
			$prev_subj = \@next_prev;
			$subj = join(' ', @subj);
			$subj = ascii_html($subj);
			obfuscate_addrs($obfs_ibx, $subj) if $obfs_ibx;
			$href = mid_href($mid);
			$s .= indent_for($level) . TCHILD;
			$s .= qq(<a\nhref="$href/T/#u">$subj</a>$omit\n);
		}
		push @out, $s;
	}
	$ctx->{-html_tip} = '<pre>' . join("\n", @out) . '</pre>';
	200;
}

sub str2ts ($) {
	my ($yyyy, $mon, $dd, $hh, $mm, $ss) = unpack('A4A2A2A2A2A2', $_[0]);
	timegm($ss || 0, $mm || 0, $hh || 0, $dd, $mon - 1, $yyyy);
}

sub pagination_footer ($$) {
	my ($ctx, $latest) = @_;
	my $next = $ctx->{next_page} || '';
	my $prev = $ctx->{prev_page} || '';
	if ($prev) {  # aligned padding for: 'next (older) | '
		$next = $next ? "$next | " : '             | ';
		$prev .= qq[ | <a\nhref="$latest">latest</a>];
	}
	($next || $prev) ? "<hr><pre id=nav>page: $next$prev</pre>" : '';
}

sub paginate_recent ($$) {
	my ($ctx, $lim) = @_;
	my $t = $ctx->{qp}->{t} || '';
	my $opts = { limit => $lim };
	my ($after, $before);

	# Xapian uses '..' but '-' is perhaps friendier to URL linkifiers
	# if only $after exists "YYYYMMDD.." because "." could be skipped
	# if interpreted as an end-of-sentence
	$t =~ s/\A([0-9]{8,14})-// and $after = str2ts($1);
	$t =~ /\A([0-9]{8,14})\z/ and $before = str2ts($1);

	my $msgs = $ctx->{ibx}->over->recent($opts, $after, $before);
	if (defined($after) && scalar(@$msgs) < $lim) {
		$after = $before = undef;
		$msgs = $ctx->{ibx}->over->recent($opts);
	}
	my $more = scalar(@$msgs) == $lim;
	my ($newest, $oldest);
	if (@$msgs) {
		$newest = $msgs->[0]->{ts};
		$oldest = $msgs->[-1]->{ts};
		# if we only had $after, our SQL query in ->recent ordered
		if ($newest < $oldest) {
			($oldest, $newest) = ($newest, $oldest);
			$more = undef if defined($after) && $after < $oldest;
		}
		if (defined($after // $before)) {
			my $n = strftime('%Y-%m-%d %H:%M:%S', gmtime($newest));
			my $o = strftime('%Y-%m-%d %H:%M:%S', gmtime($oldest));
			$ctx->{t_note} = <<EOM;
 messages from $o to $n UTC [<a href="#nav">more...</a>]
EOM
			my $s = ts2str($newest);
			$ctx->{prev_page} = qq[<a\nhref="?t=$s-"\nrel=prev>] .
						'prev (newer)</a>';
		}
	}
	if (defined($oldest) && $more) {
		my $s = ts2str($oldest);
		$ctx->{next_page} = qq[<a\nhref="?t=$s"\nrel=next>] .
					'next (older)</a>';
	}
	$msgs;
}

# GET /$INBOX - top-level inbox view for indexed inboxes
sub index_topics {
	my ($ctx) = @_;
	my $msgs = paginate_recent($ctx, 200); # 200 is our window
	walk_thread(thread_results($ctx, $msgs), $ctx, \&acc_topic) if @$msgs;
	html_oneshot($ctx, dump_topics($ctx), pagination_footer($ctx, '.'));
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
	$beg . '<pre>'. ghost_parent($ctx->{-upfx}, $node->{mid} // '?')
		. '</pre>' . $end;
}

1;
