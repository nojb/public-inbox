# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used for displaying the HTML web interface.
# See Documentation/design_www.txt for this.
package PublicInbox::View;
use strict;
use warnings;
use PublicInbox::MsgTime qw(msg_datestamp);
use PublicInbox::Hval qw/ascii_html obfuscate_addrs/;
use PublicInbox::Linkify;
use PublicInbox::MID qw/id_compress mid_escape mids references/;
use PublicInbox::MsgIter;
use PublicInbox::Address;
use PublicInbox::WwwStream;
use PublicInbox::Reply;
use PublicInbox::ViewDiff qw(flush_diff);
require POSIX;
use Time::Local qw(timegm);

use constant COLS => 72;
use constant INDENT => '  ';
use constant TCHILD => '` ';
sub th_pfx ($) { $_[0] == 0 ? '' : TCHILD };

# public functions: (unstable)

sub msg_html {
	my ($ctx, $mime, $more, $smsg) = @_;
	my $hdr = $mime->header_obj;
	my $ibx = $ctx->{-inbox};
	$ctx->{-obfs_ibx} = $ibx->{obfuscate} ? $ibx : undef;
	my $tip = _msg_html_prepare($hdr, $ctx, $more, 0);
	my $end = 2;
	PublicInbox::WwwStream->response($ctx, 200, sub {
		my ($nr, undef) = @_;
		if ($nr == 1) {
			# $more cannot be true w/o $smsg being defined:
			my $upfx = $more ? '../'.mid_escape($smsg->mid).'/' : '';
			$tip . multipart_text_as_html($mime, $upfx, $ctx) .
				'</pre><hr>'
		} elsif ($more && @$more) {
			++$end;
			msg_html_more($ctx, $more, $nr);
		} elsif ($nr == $end) {
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

sub msg_page {
	my ($ctx) = @_;
	my $mid = $ctx->{mid};
	my $ibx = $ctx->{-inbox};
	my ($first, $more);
	my $smsg;
	if (my $srch = $ibx->search) {
		my ($id, $prev);
		$smsg = $srch->next_by_mid($mid, \$id, \$prev);
		$first = $ibx->msg_by_smsg($smsg) if $smsg;
		if ($first) {
			my $next = $srch->next_by_mid($mid, \$id, \$prev);
			$more = [ $id, $prev, $next ] if $next;
		}
		return unless $first;
	} else {
		$first = $ibx->msg_by_mid($mid) or return;
	}
	msg_html($ctx, PublicInbox::MIME->new($first), $more, $smsg);
}

sub msg_html_more {
	my ($ctx, $more, $nr) = @_;
	my $str = eval {
		my ($id, $prev, $smsg) = @$more;
		my $mid = $ctx->{mid};
		my $ibx = $ctx->{-inbox};
		$smsg = $ibx->smsg_mime($smsg);
		my $next = $ctx->{srch}->next_by_mid($mid, \$id, \$prev);
		@$more = $next ? ($id, $prev, $next) : ();
		if ($smsg) {
			my $mime = $smsg->{mime};
			my $upfx = '../' . mid_escape($smsg->mid) . '/';
			_msg_html_prepare($mime->header_obj, $ctx, $more, $nr) .
				multipart_text_as_html($mime, $upfx, $ctx) .
				'</pre><hr>'
		} else {
			'';
		}
	};
	if ($@) {
		warn "Error lookup up additional messages: $@\n";
		$str = '<pre>Error looking up additional messages</pre>';
	}
	$str;
}

# /$INBOX/$MESSAGE_ID/#R
sub msg_reply {
	my ($ctx, $hdr) = @_;
	my $se_url =
	 'https://kernel.org/pub/software/scm/git/docs/git-send-email.html';
	my $p_url =
	 'https://en.wikipedia.org/wiki/Posting_style#Interleaved_style';

	my $info = '';
	my $ibx = $ctx->{-inbox};
	if (my $url = $ibx->{infourl}) {
		$url = PublicInbox::Hval::prurl($ctx->{env}, $url);
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

You may reply publically to <a
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
	# Try to get the "," preceeded by ">" or ")", but avoid folding
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
	my ($smsg, $ctx, $more) = @_;
	my $srch = $ctx->{srch};
	my $subj = $smsg->subject;
	my $mid_raw = $smsg->mid;
	my $id = id_compress($mid_raw, 1);
	my $id_m = 'm'.$id;

	my $root_anchor = $ctx->{root_anchor} || '';
	my $irt;
	my $obfs_ibx = $ctx->{-obfs_ibx};

	my $rv = "<a\nhref=#e$id\nid=m$id>*</a> ";
	$subj = '<b>'.ascii_html($subj).'</b>';
	obfuscate_addrs($obfs_ibx, $subj) if $obfs_ibx;
	$subj = "<u\nid=u>$subj</u>" if $root_anchor eq $id_m;
	$rv .= $subj . "\n";
	$rv .= _th_index_lite($mid_raw, \$irt, $id, $ctx);
	my @tocc;
	my $ds = $smsg->ds; # for v1 non-Xapian/SQLite users
	# deleting {mime} is critical to memory use,
	# the rest of the fields saves about 400K as we iterate across 1K msgs
	my ($mime) = delete @$smsg{qw(mime ds ts blob subject)};

	my $hdr = $mime->header_obj;
	my $from = _hdr_names_html($hdr, 'From');
	obfuscate_addrs($obfs_ibx, $from) if $obfs_ibx;
	$rv .= "From: $from @ ".fmt_ts($ds)." UTC";
	my $upfx = $ctx->{-upfx};
	my $mhref = $upfx . mid_escape($mid_raw) . '/';
	$rv .= qq{ (<a\nhref="$mhref">permalink</a> / };
	$rv .= qq{<a\nhref="${mhref}raw">raw</a>)\n};
	my $to = fold_addresses(_hdr_names_html($hdr, 'To'));
	my $cc = fold_addresses(_hdr_names_html($hdr, 'Cc'));
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
	if (!$mapping && (defined($irt) || defined($irt = in_reply_to($hdr)))) {
		my $mirt = PublicInbox::Hval->new_msgid($irt);
		my $href = $upfx . $mirt->{href}. '/';
		my $html = $mirt->as_html;
		$rv .= qq(In-Reply-To: &lt;<a\nhref="$href">$html</a>&gt;\n)
	}
	$rv .= "\n";

	# scan through all parts, looking for displayable text
	my $ibx = $ctx->{-inbox};
	msg_iter($mime, sub { $rv .= add_text_body($mhref, $ctx, $_[0]) });

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
		my $nested = 'nested';
		my $flat = 'flat';
		my $end = '';
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
	my $mid_map = $mapping->{$mid_raw};
	defined $mid_map or
		return 'public-inbox BUG: '.ascii_html($mid_raw).' not mapped';
	my ($attr, $node, $idx, $level) = @$mid_map;
	my $children = $node->{children};
	my $nr_c = scalar @$children;
	my $nr_s = 0;
	my $siblings;
	if (my $smsg = $node->{smsg}) {
		# delete saves about 200KB on a 1K message thread
		if (my $refs = delete $smsg->{references}) {
			($$irt) = ($refs =~ m/<([^>]+)>\z/);
		}
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

sub pre_thread  {
	my ($ctx, $level, $node, $idx) = @_;
	$ctx->{mapping}->{$node->{id}} = [ '', $node, $idx, $level ];
	skel_dump($ctx, $level, $node);
}

sub thread_index_entry {
	my ($ctx, $level, $smsg) = @_;
	my ($beg, $end) = thread_adj_level($ctx, $level);
	$beg . '<pre>' . index_entry($smsg, $ctx, 0) . '</pre>' . $end;
}

sub stream_thread ($$) {
	my ($rootset, $ctx) = @_;
	my $inbox = $ctx->{-inbox};
	my @q = map { (0, $_) } @$rootset;
	my $level;
	my $smsg;
	while (@q) {
		$level = shift @q;
		my $node = shift @q or next;
		my $cl = $level + 1;
		unshift @q, map { ($cl, $_) } @{$node->{children}};
		$smsg = $inbox->smsg_mime($node->{smsg}) and last;
	}
	return missing_thread($ctx) unless $smsg;

	$ctx->{-obfs_ibx} = $inbox->{obfuscate} ? $inbox : undef;
	$ctx->{-title_html} = ascii_html($smsg->subject);
	$ctx->{-html_tip} = thread_index_entry($ctx, $level, $smsg);
	$smsg = undef;
	PublicInbox::WwwStream->response($ctx, 200, sub {
		return unless $ctx;
		while (@q) {
			$level = shift @q;
			my $node = shift @q or next;
			my $cl = $level + 1;
			unshift @q, map { ($cl, $_) } @{$node->{children}};
			if ($smsg = $inbox->smsg_mime($node->{smsg})) {
				return thread_index_entry($ctx, $level, $smsg);
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
	my ($nr, $msgs) = $srch->get_thread($mid);
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
	$ctx->{mapping} = {};
	$ctx->{s_nr} = "$nr+ messages in thread";

	my $rootset = thread_results($ctx, $msgs);

	# reduce hash lookups in pre_thread->skel_dump
	my $inbox = $ctx->{-inbox};
	$ctx->{-obfs_ibx} = $inbox->{obfuscate} ? $inbox : undef;
	walk_thread($rootset, $ctx, *pre_thread);

	$skel .= '</pre>';
	return stream_thread($rootset, $ctx) unless $ctx->{flat};

	# flat display: lazy load the full message from smsg
	my $smsg;
	while (my $m = shift @$msgs) {
		$smsg = $inbox->smsg_mime($m) and last;
	}
	return missing_thread($ctx) unless $smsg;
	$ctx->{-title_html} = ascii_html($smsg->subject);
	$ctx->{-html_tip} = '<pre>'.index_entry($smsg, $ctx, scalar @$msgs);
	$smsg = undef;
	PublicInbox::WwwStream->response($ctx, 200, sub {
		return unless $msgs;
		$smsg = undef;
		while (my $m = shift @$msgs) {
			$smsg = $inbox->smsg_mime($m) and last;
		}
		return index_entry($smsg, $ctx, scalar @$msgs) if $smsg;
		$msgs = undef;
		$skel;
	});
}

sub multipart_text_as_html {
	my ($mime, $upfx, $ctx) = @_;
	my $rv = "";

	# scan through all parts, looking for displayable text
	msg_iter($mime, sub { $rv .= add_text_body($upfx, $ctx, $_[0]) });
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
	$desc = ascii_html($desc);
	$ret .= ($desc eq '') ? "$ts --]" : "$desc --]\n[-- $ts --]";
	$ret .= "</a>\n";
}

sub add_text_body {
	my ($upfx, $ctx, $p) = @_;
	my $ibx = $ctx->{-inbox};
	my $obfs_ibx = $ibx->{obfuscate} ? $ibx : undef;
	# $p - from msg_iter: [ Email::MIME, depth, @idx ]
	my ($part, $depth, @idx) = @$p;
	my $ct = $part->content_type || 'text/plain';
	my $fn = $part->filename;
	my ($s, $err) = msg_part_text($part, $ct);

	return attach_link($upfx, $ct, $p, $fn) unless defined $s;

	# makes no difference to browsers, and don't screw up filename
	# link generation in diffs with the extra '%0D'
	$s =~ s/\r\n/\n/sg;

	# always support diff-highlighting, but we can't linkify hunk
	# headers for solver unless some coderepo are configured:
	my $diff;
	if ($s =~ /^(?:diff|---|\+{3}) /ms) {
		# diffstat anchors do not link across attachments or messages:
		$idx[0] = $upfx . $idx[0] if $upfx ne '';
		$ctx->{-apfx} = join('/', @idx);
		$ctx->{-anchors} = {}; # attr => filename
		$ctx->{-diff} = $diff = [];
		my $spfx;
		if ($ibx->{-repo_objs}) {
			if (index($upfx, '//') >= 0) { # absolute URL (Atom feeds)
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

	my @lines = split(/^/m, $s);
	$s = '';
	if (defined($fn) || $depth > 0 || $err) {
		# badly-encoded message with $err? tell the world about it!
		$s .= attach_link($upfx, $ct, $p, $fn, $err);
		$s .= "\n";
	}
	my @quot;
	my $l = PublicInbox::Linkify->new;
	foreach my $cur (@lines) {
		if ($cur !~ /^>/) {
			# show the previously buffered quote inline
			flush_quote(\$s, $l, \@quot) if @quot;

			if ($diff) {
				push @$diff, $cur;
			} else {
				# regular line, OK
				$l->linkify_1($cur);
				$s .= $l->linkify_2(ascii_html($cur));
			}
		} else {
			flush_diff(\$s, $ctx, $l) if $diff && @$diff;
			push @quot, $cur;
		}
	}

	if (@quot) { # ugh, top posted
		flush_quote(\$s, $l, \@quot);
		flush_diff(\$s, $ctx, $l) if $diff && @$diff;
		obfuscate_addrs($obfs_ibx, $s) if $obfs_ibx;
		$s;
	} else {
		flush_diff(\$s, $ctx, $l) if $diff && @$diff;
		obfuscate_addrs($obfs_ibx, $s) if $obfs_ibx;
		if ($s =~ /\n\z/s) { # common, last line ends with a newline
			$s;
		} else { # some editors don't do newlines...
			$s .= "\n";
		}
	}
}

sub _msg_html_prepare {
	my ($hdr, $ctx, $more, $nr) = @_;
	my $srch = $ctx->{srch} if $ctx;
	my $atom = '';
	my $obfs_ibx = $ctx->{-obfs_ibx};
	my $rv = '';
	my $mids = mids($hdr);
	my $multiple = scalar(@$mids) > 1; # zero, one, infinity
	if ($nr == 0) {
		if ($more) {
			$rv .=
"<pre>WARNING: multiple messages refer to this Message-ID\n</pre>";
		}
		$rv .= "<pre\nid=b>"; # anchor for body start
	} else {
		$rv .= '<pre>';
	}
	if ($srch) {
		$ctx->{-upfx} = '../';
	}
	my @title;
	my $v;
	if (defined($v = $hdr->header('From'))) {
		$v = PublicInbox::Hval->new($v);
		my @n = PublicInbox::Address::names($v->raw);
		$title[1] = ascii_html(join(', ', @n));
		$v = $v->as_html;
		if ($obfs_ibx) {
			obfuscate_addrs($obfs_ibx, $v);
			obfuscate_addrs($obfs_ibx, $title[1]);
		}
		$rv .= "From: $v\n" if $v ne '';
	}
	foreach my $h (qw(To Cc)) {
		defined($v = $hdr->header($h)) or next;
		fold_addresses($v);
		$v = ascii_html($v);
		obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx;
		$rv .= "$h: $v\n" if $v ne '';
	}
	if (defined($v = $hdr->header('Subject')) && ($v ne '')) {
		$v = ascii_html($v);
		obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx;
		if ($srch) {
			$rv .= qq(Subject: <a\nhref="#r"\nid=t>$v</a>\n);
		} else {
			$rv .= "Subject: $v\n";
		}
		$title[0] = $v;
	} else { # dummy anchor for thread skeleton at bottom of page
		$rv .= qq(<a\nhref="#r"\nid=t></a>) if $srch;
		$title[0] = '(no subject)';
	}
	if (defined($v = $hdr->header('Date'))) {
		$v = ascii_html($v);
		obfuscate_addrs($obfs_ibx, $v) if $obfs_ibx; # possible :P
		$rv .= "Date: $v\n";
	}
	$ctx->{-title_html} = join(' - ', @title);
	foreach (@$mids) {
		my $mid = PublicInbox::Hval->new_msgid($_) ;
		my $mhtml = $mid->as_html;
		if ($multiple) {
			my $href = $mid->{href};
			$rv .= "Message-ID: ";
			$rv .= "<a\nhref=\"../$href/\">";
			$rv .= "&lt;$mhtml&gt;</a> ";
			$rv .= "(<a\nhref=\"../$href/raw\">raw</a>)\n";
		} else {
			$rv .= "Message-ID: &lt;$mhtml&gt; ";
			$rv .= "(<a\nhref=\"raw\">raw</a>)\n";
		}
	}
	$rv .= _parent_headers($hdr, $srch);
	$rv .= "\n";
}

sub thread_skel {
	my ($dst, $ctx, $hdr, $tpfx) = @_;
	my $srch = $ctx->{srch};
	my $mid = mids($hdr)->[0];
	my ($nr, $msgs) = $srch->get_thread($mid);
	my $expand = qq(expand[<a\nhref="${tpfx}T/#u">flat</a>) .
	                qq(|<a\nhref="${tpfx}t/#u">nested</a>]  ) .
			qq(<a\nhref="${tpfx}t.mbox.gz">mbox.gz</a>  ) .
			qq(<a\nhref="${tpfx}t.atom">Atom feed</a>);

	my $parent = in_reply_to($hdr);
	$$dst .= "\n<b>Thread overview: </b>";
	if ($nr <= 1) {
		if (defined $parent) {
			$$dst .= "$expand\n ";
			$$dst .= ghost_parent("$tpfx../", $parent) . "\n";
		} else {
			$$dst .= "[no followups] $expand\n";
		}
		$ctx->{next_msg} = undef;
		$ctx->{parent_msg} = $parent;
		return;
	}

	$$dst .= "$nr+ messages / $expand";
	$$dst .= qq!  <a\nhref="#b">top</a>\n!;

	my $subj = $hdr->header('Subject');
	defined $subj or $subj = '';
	$ctx->{prev_subj} = [ split(/ /, $srch->subject_normalized($subj)) ];
	$ctx->{cur} = $mid;
	$ctx->{prev_attr} = '';
	$ctx->{prev_level} = 0;
	$ctx->{dst} = $dst;

	# reduce hash lookups in skel_dump
	my $ibx = $ctx->{-inbox};
	$ctx->{-obfs_ibx} = $ibx->{obfuscate} ? $ibx : undef;
	walk_thread(thread_results($ctx, $msgs), $ctx, *skel_dump);

	$ctx->{parent_msg} = $parent;
}

sub _parent_headers {
	my ($hdr, $srch) = @_;
	my $rv = '';

	my $refs = references($hdr);
	my $irt = pop @$refs;
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

	if (@$refs) {
		@$refs = map { linkify_ref_nosrch($_) } @$refs;
		$rv .= 'References: '. join("\n\t", @$refs) . "\n";
	}
	$rv;
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
	$level ? INDENT x ($level - 1) : '';
}

sub find_mid_root {
	my ($ctx, $level, $node, $idx) = @_;
	++$ctx->{root_idx} if $level == 0;
	if ($node->{id} eq $ctx->{mid}) {
		$ctx->{found_mid_at} = $ctx->{root_idx};
		return 0;
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
	my $ibx = $ctx->{-inbox};
	my $rootset = PublicInbox::SearchThread::thread($msgs, *sort_ds, $ibx);

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
		walk_thread($rootset, $ctx, *find_mid_root);
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

sub fmt_ts { POSIX::strftime('%Y-%m-%d %k:%M', gmtime($_[0])) }

sub dedupe_subject {
	my ($prev_subj, $subj, $val) = @_;

	my $omit = ''; # '"' denotes identical text omitted
	my (@prev_pop, @curr_pop);
	while (@$prev_subj && @$subj && $subj->[-1] eq $prev_subj->[-1]) {
		push(@prev_pop, pop(@$prev_subj));
		push(@curr_pop, pop(@$subj));
		$omit ||= $val;
	}
	pop @$subj if @$subj && $subj->[-1] =~ /^re:\s*/i;
	if (scalar(@curr_pop) == 1) {
		$omit = '';
		push @$prev_subj, @prev_pop;
		push @$subj, @curr_pop;
	}
	$omit;
}

sub skel_dump {
	my ($ctx, $level, $node) = @_;
	my $smsg = $node->{smsg} or return _skel_ghost($ctx, $level, $node);

	my $dst = $ctx->{dst};
	my $cur = $ctx->{cur};
	my $mid = $smsg->{mid};

	if ($level == 0 && $ctx->{skel_dump_roots}++) {
		$$dst .= delete $ctx->{sl_note} || '';
	}

	my $f = ascii_html($smsg->from_name);
	my $obfs_ibx = $ctx->{-obfs_ibx};
	obfuscate_addrs($obfs_ibx, $f) if $obfs_ibx;

	my $d = fmt_ts($smsg->{ds}) . ' ' . indent_for($level) . th_pfx($level);
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
	my @subj = split(/ /, $ctx->{srch}->subject_normalized($smsg->subject));

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
	my $mapping = $ctx->{mapping};
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
	1;
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
	1;
}

sub sort_ds {
	[ sort {
		(eval { $a->topmost->{smsg}->ds } || 0) <=>
		(eval { $b->topmost->{smsg}->ds } || 0)
	} @{$_[0]} ];
}

# accumulate recent topics if search is supported
# returns 200 if done, 404 if not
sub acc_topic {
	my ($ctx, $level, $node) = @_;
	my $srch = $ctx->{srch};
	my $mid = $node->{id};
	my $x = $node->{smsg} || $ctx->{-inbox}->smsg_by_mid($mid);
	my ($subj, $ds);
	my $topic;
	if ($x) {
		$subj = $x->subject;
		$subj = $srch->subject_normalized($subj);
		$ds = $x->ds;
		if ($level == 0) {
			$topic = [ $ds, 1, { $subj => $mid }, $subj ];
			$ctx->{-cur_topic} = $topic;
			push @{$ctx->{order}}, $topic;
			return 1;
		}

		$topic = $ctx->{-cur_topic}; # should never be undef
		$topic->[0] = $ds if $ds > $topic->[0];
		$topic->[1]++;
		my $seen = $topic->[2];
		if (scalar(@$topic) == 3) { # parent was a ghost
			push @$topic, $subj;
		} elsif (!$seen->{$subj}) {
			push @$topic, $level, $subj;
		}
		$seen->{$subj} = $mid; # latest for subject
	} else { # ghost message
		return 1 if $level != 0; # ignore child ghosts
		$topic = [ -666, 0, {} ];
		$ctx->{-cur_topic} = $topic;
		push @{$ctx->{order}}, $topic;
	}
	1;
}

sub dump_topics {
	my ($ctx) = @_;
	my $order = delete $ctx->{order}; # [ ds, subj1, subj2, subj3, ... ]
	if (!@$order) {
		$ctx->{-html_tip} = '<pre>[No topics in range]</pre>';
		return 404;
	}

	my @out;
	my $ibx = $ctx->{-inbox};
	my $obfs_ibx = $ibx->{obfuscate} ? $ibx : undef;
	my $srch = $ctx->{srch};

	# sort by recency, this allows new posts to "bump" old topics...
	foreach my $topic (sort { $b->[0] <=> $a->[0] } @$order) {
		my ($ds, $n, $seen, $top, @ex) = @$topic;
		@$topic = ();
		next unless defined $top;  # ghost topic
		my $mid = delete $seen->{$top};
		my $href = mid_escape($mid);
		my $prev_subj = [ split(/ /, $top) ];
		$top = PublicInbox::Hval->new($top)->as_html;
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

		my $mbox = qq(<a\nhref="$href/t.mbox.gz">mbox.gz</a>);
		my $atom = qq(<a\nhref="$href/t.atom">Atom</a>);
		my $s = "<a\nhref=\"$href/T/$anchor\">$top</a>\n" .
			" $ds UTC $n - $mbox / $atom\n";
		for (my $i = 0; $i < scalar(@ex); $i += 2) {
			my $level = $ex[$i];
			my $subj = $ex[$i + 1];
			$mid = delete $seen->{$subj};
			my @subj = split(/ /, $srch->subject_normalized($subj));
			my @next_prev = @subj; # full copy
			my $omit = dedupe_subject($prev_subj, \@subj, ' &#34;');
			$prev_subj = \@next_prev;
			$subj = ascii_html(join(' ', @subj));
			obfuscate_addrs($obfs_ibx, $subj) if $obfs_ibx;
			$href = mid_escape($mid);
			$s .= indent_for($level) . TCHILD;
			$s .= "<a\nhref=\"$href/T/#u\">$subj</a>$omit\n";
		}
		push @out, $s;
	}
	$ctx->{-html_tip} = '<pre>' . join("\n", @out) . '</pre>';
	200;
}

sub ts2str ($) {
	my ($ts) = @_;
	POSIX::strftime('%Y%m%d%H%M%S', gmtime($ts));
}

sub str2ts ($) {
	my ($yyyy, $mon, $dd, $hh, $mm, $ss) = unpack('A4A2A2A2A2A2', $_[0]);
	timegm($ss, $mm, $hh, $dd, $mon - 1, $yyyy);
}

sub pagination_footer ($$) {
	my ($ctx, $latest) = @_;
	delete $ctx->{qp} or return;
	my $next = $ctx->{next_page} || '';
	my $prev = $ctx->{prev_page} || '';
	if ($prev) {
		$next = $next ? "$next " : '     ';
		$prev .= qq! <a\nhref='$latest'>latest</a>!;
	}
	"<hr><pre>page: $next$prev</pre>";
}

sub index_nav { # callback for WwwStream
	my (undef, $ctx) = @_;
	pagination_footer($ctx, '.')
}

sub paginate_recent ($$) {
	my ($ctx, $lim) = @_;
	my $t = $ctx->{qp}->{t} || '';
	my $opts = { limit => $lim };
	my ($after, $before);

	# Xapian uses '..' but '-' is perhaps friendier to URL linkifiers
	# if only $after exists "YYYYMMDD.." because "." could be skipped
	# if interpreted as an end-of-sentence
	$t =~ s/\A(\d{8,14})-// and $after = str2ts($1);
	$t =~ /\A(\d{8,14})\z/ and $before = str2ts($1);

	my $ibx = $ctx->{-inbox};
	my $msgs = $ibx->recent($opts, $after, $before);
	my $nr = scalar @$msgs;
	if ($nr < $lim && defined($after)) {
		$after = $before = undef;
		$msgs = $ibx->recent($opts);
		$nr = scalar @$msgs;
	}
	my $more = $nr == $lim;
	my ($newest, $oldest);
	if ($nr) {
		$newest = $msgs->[0]->{ts};
		$oldest = $msgs->[-1]->{ts};
		# if we only had $after, our SQL query in ->recent ordered
		if ($newest < $oldest) {
			($oldest, $newest) = ($newest, $oldest);
			$more = 0 if defined($after) && $after < $oldest;
		}
	}
	if (defined($oldest) && $more) {
		my $s = ts2str($oldest);
		$ctx->{next_page} = qq!<a\nhref="?t=$s"\nrel=next>next</a>!;
	}
	if (defined($newest) && (defined($before) || defined($after))) {
		my $s = ts2str($newest);
		$ctx->{prev_page} = qq!<a\nhref="?t=$s-"\nrel=prev>prev</a>!;
	}
	$msgs;
}

sub index_topics {
	my ($ctx) = @_;
	my $msgs = paginate_recent($ctx, 200); # 200 is our window
	if (@$msgs) {
		walk_thread(thread_results($ctx, $msgs), $ctx, *acc_topic);
	}
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
