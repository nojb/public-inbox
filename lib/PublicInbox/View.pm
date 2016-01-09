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
use Encode qw/find_encoding/;
use Encode::MIME::Header;
use Email::MIME::ContentType qw/parse_content_type/;
use PublicInbox::Hval;
use PublicInbox::MID qw/mid_clean id_compress mid2path/;
use Digest::SHA qw/sha1_hex/;
my $SALT = rand;
require POSIX;

# TODO: make these constants tunable
use constant MAX_INLINE_QUOTED => 12; # half an 80x24 terminal
use constant MAX_TRUNC_LEN => 72;
use constant T_ANCHOR => '#u';
use constant INDENT => '  ';

*ascii_html = *PublicInbox::Hval::ascii_html;

my $enc_utf8 = find_encoding('UTF-8');

# public functions:
sub msg_html {
	my ($ctx, $mime, $full_pfx, $footer) = @_;
	if (defined $footer) {
		$footer = "\n" . $footer;
	} else {
		$footer = '';
	}
	headers_to_html_header($mime, $full_pfx, $ctx) .
		multipart_text_as_html($mime, $full_pfx) .
		'</pre><hr /><pre>' .
		html_footer($mime, 1, $full_pfx, $ctx) .
		$footer .
		'</pre></body></html>';
}

sub feed_entry {
	my ($class, $mime, $full_pfx) = @_;

	# no <head> here for <style>...
	PublicInbox::Hval::PRE .
		multipart_text_as_html($mime, $full_pfx) . '</pre>';
}

sub in_reply_to {
	my ($header_obj) = @_;
	my $irt = $header_obj->header('In-Reply-To');

	return mid_clean($irt) if (defined $irt);

	my $refs = $header_obj->header('References');
	if ($refs && $refs =~ /<([^>]+)>\s*\z/s) {
		return $1;
	}
	undef;
}

# this is already inside a <pre>
sub index_entry {
	my ($fh, $mime, $level, $state) = @_;
	my $midx = $state->{anchor_idx}++;
	my $ctx = $state->{ctx};
	my $srch = $ctx->{srch};
	my ($prev, $next) = ($midx - 1, $midx + 1);
	my $part_nr = 0;
	my $enc = enc_for($mime->header("Content-Type"));
	my $subj = $mime->header('Subject');
	my $header_obj = $mime->header_obj;

	my $mid_raw = mid_clean($header_obj->header('Message-ID'));
	my $id = anchor_for($mid_raw);
	my $seen = $state->{seen};
	$seen->{$id} = "#$id"; # save the anchor for children, later

	my $mid = PublicInbox::Hval->new_msgid($mid_raw);
	my $from = PublicInbox::Hval->new_oneline($mime->header('From'))->raw;
	my @from = Email::Address->parse($from);
	$from = $from[0]->name;

	$from = PublicInbox::Hval->new_oneline($from)->as_html;
	$subj = PublicInbox::Hval->new_oneline($subj)->as_html;
	my $root_anchor = $state->{root_anchor} || '';
	my $path = $root_anchor ? '../../' : '';
	my $href = $mid->as_href;
	my $irt = in_reply_to($header_obj);
	my $parent_anchor = $seen->{anchor_for($irt)} if defined $irt;

	if ($srch) {
		my $t = $ctx->{flat} ? 'T' : 't';
		$subj = "<a\nhref=\"${path}$href/$t/#u\">$subj</a>";
	}
	if ($root_anchor eq $id) {
		$subj = "<u\nid=u>$subj</u>";
	}

	my $ts = _msg_date($mime);
	my $rv = "<pre\nid=s$midx>";
	$rv .= "<b\nid=$id>$subj</b>\n";
	$rv .= "- $from @ $ts UTC - ";
	$rv .= "<a\nhref=\"#s$next\">next</a>";
	if ($prev >= 0) {
		$rv .= "/<a\nhref=\"#s$prev\">prev</a>";
	}
	$fh->write($rv .= "\n\n");

	my ($fhref, $more_ref);
	my $mhref = "${path}$href/";
	my $more = 'permalink';

	# show full message if it's our root message
	my $neq = $root_anchor ne $id;
	if ($neq || ($neq && $level != 0 && !$ctx->{flat})) {
		$fhref = "${path}$href/f/";
		$more_ref = \$more;
	}
	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		index_walk($fh, $_[0], $enc, \$part_nr, $fhref, $more_ref);
	});
	$mime->body_set('');

	my $txt = "${path}$href/raw";
	$rv = "\n<a\nhref=\"$mhref\">$more</a> <a\nhref=\"$txt\">raw</a> ";
	$rv .= html_footer($mime, 0, undef, $ctx);

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
		if ($ctx->{flat}) {
			$rv .= " [<a\nhref=\"${path}$href/t/#u\">threaded</a>" .
				"|<b>flat</b>]";
		} else {
			$rv .= " [<b>threaded</b>|" .
				"<a\nhref=\"${path}$href/T/#u\">flat</a>]";
		}
	}
	$fh->write($rv .= '</pre>');
}

sub thread_html {
	my ($ctx, $foot, $srch) = @_;
	sub { emit_thread_html($_[0], $ctx, $foot, $srch) }
}

# only private functions below.

sub emit_thread_html {
	my ($cb, $ctx, $foot, $srch) = @_;
	my $mid = $ctx->{mid};
	my $res = $srch->get_thread($mid);
	my $msgs = load_results($res);
	my $nr = scalar @$msgs;
	return missing_thread($cb, $ctx) if $nr == 0;
	my $flat = $ctx->{flat};
	my $orig_cb = $cb;
	my $seen = {};
	my $state = {
		ctx => $ctx,
		seen => $seen,
		root_anchor => anchor_for($mid),
		anchor_idx => 0,
		cur_level => 0,
	};

	require PublicInbox::Git;
	my $git = $ctx->{git} ||= PublicInbox::Git->new($ctx->{git_dir});
	if ($flat) {
		pre_anchor_entry($seen, $_) for (@$msgs);
		__thread_entry(\$cb, $git, $state, $_, 0) for (@$msgs);
	} else {
		my $th = thread_results($msgs);
		thread_entry(\$cb, $git, $state, $_, 0) for $th->rootset;
		if (my $max = $state->{cur_level}) {
			$cb->write(('</ul></li>' x ($max - 1)) . '</ul>');
		}
	}
	$git = undef;
	Email::Address->purge_cache;

	# there could be a race due to a message being deleted in git
	# but still being in the Xapian index:
	return missing_thread($cb, $ctx) if ($orig_cb eq $cb);

	my $final_anchor = $state->{anchor_idx};
	my $next = "<a\nid=s$final_anchor>";
	$next .= $final_anchor == 1 ? 'only message in' : 'end of';
	$next .= " thread</a>, back to <a\nhref=\"../../\">index</a>";
	$next .= "\ndownload thread: ";
	$next .= "<a\nhref=\"../t.mbox.gz\">mbox.gz</a>";
	$next .= " / follow: <a\nhref=\"../t.atom\">Atom feed</a>";
	$cb->write('<hr /><pre>' . $next . "\n\n".
			$foot .  '</pre></body></html>');
	$cb->close;
}

sub index_walk {
	my ($fh, $part, $enc, $part_nr, $fhref, $more) = @_;
	my $s = add_text_body($enc, $part, $part_nr, $fhref);

	if ($more) {
		my $m = 0;
		# drop the remainder of git patches, they're usually better
		# to review when the full message is viewed
		$s =~ s!^---+\n.*\z!!ms and $m = 1;

		# Drop signatures
		$s =~ s/^-- \n.*\z//ms and $m = 1;
		$$more = "<b>More...</b>\n\n$$more" if $m;
	}

	# kill any leading or trailing whitespace lines
	$s =~ s/^\s*$//sgm;
	$s =~ s/\s+\z//s;

	if ($s ne '') {
		# kill per-line trailing whitespace
		$s =~ s/[ \t]+$//sgm;
		$s .= "\n" unless $s =~ /\n\z/s;
	}
	$fh->write($s);
}

sub enc_for {
	my ($ct, $default) = @_;
	$default ||= $enc_utf8;
	defined $ct or return $default;
	my $ct_parsed = parse_content_type($ct);
	if ($ct_parsed) {
		if (my $charset = $ct_parsed->{attributes}->{charset}) {
			my $enc = find_encoding($charset);
			return $enc if $enc;
		}
	}
	$default;
}

sub multipart_text_as_html {
	my ($mime, $full_pfx, $srch) = @_;
	my $rv = "";
	my $part_nr = 0;
	my $enc = enc_for($mime->header("Content-Type"));

	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		my ($part) = @_;
		$rv .= add_text_body($enc, $part, \$part_nr, $full_pfx, 1);
	});
	$mime->body_set('');
	$rv;
}

sub add_filename_line {
	my ($enc, $fn) = @_;
	my $len = 72;
	my $pad = "-";
	$fn = $enc->decode($fn);
	$len -= length($fn);
	$pad x= ($len/2) if ($len > 0);
	"$pad " . ascii_html($fn) . " $pad\n";
}

my $LINK_RE = qr!\b((?:ftp|https?|nntp)://
		 [\@:\w\.-]+/
		 ?[\@\w\+\&\?\.\%\;/#=-]*)!x;

sub linkify_1 {
	my ($link_map, $s) = @_;
	$s =~ s!$LINK_RE!
		my $url = $1;
		# salt this, as this could be exploited to show
		# links in the HTML which don't show up in the raw mail.
		my $key = sha1_hex($url . $SALT);
		$link_map->{$key} = $url;
		'PI-LINK-'. $key;
	!ge;
	$s;
}

sub linkify_2 {
	my ($link_map, $s) = @_;

	# Added "PI-LINK-" prefix to avoid false-positives on git commits
	$s =~ s!\bPI-LINK-([a-f0-9]{40})\b!
		my $key = $1;
		my $url = $link_map->{$key};
		if (defined $url) {
			$url = ascii_html($url);
			"<a\nhref=\"$url\">$url</a>";
		} else {
			# false positive or somebody tried to mess with us
			$key;
		}
	!ge;
	$s;
}

sub flush_quote {
	my ($quot, $n, $part_nr, $full_pfx, $final, $do_anchor) = @_;

	if ($full_pfx) {
		if (!$final && scalar(@$quot) <= MAX_INLINE_QUOTED) {
			# show quote inline
			my %l;
			my $rv = join('', map { linkify_1(\%l, $_) } @$quot);
			@$quot = ();
			$rv = ascii_html($rv);
			return linkify_2(\%l, $rv);
		}

		# show a short snippet of quoted text and link to full version:
		@$quot = map { s/^(?:>\s*)+//gm; $_ } @$quot;
		my $cur = join(' ', @$quot);
		@$quot = split(/\s+/, $cur);
		$cur = '';
		do {
			my $tmp = shift(@$quot);
			my $len = length($tmp) + length($cur);
			if ($len > MAX_TRUNC_LEN) {
				@$quot = ();
			} else {
				$cur .= $tmp . ' ';
			}
		} while (@$quot && length($cur) < MAX_TRUNC_LEN);
		@$quot = ();
		$cur =~ s/ \z/ .../s;
		$cur = ascii_html($cur);
		my $nr = ++$$n;
		"&gt; [<a\nhref=\"$full_pfx#q${part_nr}_$nr\">$cur</a>]\n";
	} else {
		# show everything in the full version with anchor from
		# short version (see above)
		my %l;
		my $rv .= join('', map { linkify_1(\%l, $_) } @$quot);
		@$quot = ();
		$rv = ascii_html($rv);
		return linkify_2(\%l, $rv) unless $do_anchor;
		my $nr = ++$$n;
		"<a\nid=q${part_nr}_$nr></a>" . linkify_2(\%l, $rv);
	}
}

sub add_text_body {
	my ($enc_msg, $part, $part_nr, $full_pfx, $do_anchor) = @_;
	return '' if $part->subparts;

	my $ct = $part->content_type;
	# account for filter bugs...
	if (defined $ct && $ct =~ m!\btext/x?html\b!i) {
		$part->body_set('');
		return '';
	}
	my $enc = enc_for($ct, $enc_msg);
	my $n = 0;
	my $nr = 0;
	my $s = $part->body;
	$part->body_set('');
	$s = $enc->decode($s);
	my @lines = split(/^/m, $s);
	$s = '';

	if ($$part_nr > 0) {
		my $fn = $part->filename;
		defined($fn) or $fn = "part #" . ($$part_nr + 1);
		$s .= add_filename_line($enc, $fn);
	}

	my @quot;
	while (defined(my $cur = shift @lines)) {
		if ($cur !~ /^>/) {
			# show the previously buffered quote inline
			if (scalar @quot) {
				$s .= flush_quote(\@quot, \$n, $$part_nr,
						  $full_pfx, 0, $do_anchor);
			}

			# regular line, OK
			my %l;
			$cur = linkify_1(\%l, $cur);
			$cur = ascii_html($cur);
			$s .= linkify_2(\%l, $cur);
		} else {
			push @quot, $cur;
		}
	}
	if (scalar @quot) {
		$s .= flush_quote(\@quot, \$n, $$part_nr, $full_pfx, 1,
				  $do_anchor);
	}
	$s .= "\n" unless $s =~ /\n\z/s;
	++$$part_nr;
	$s;
}

sub headers_to_html_header {
	my ($mime, $full_pfx, $ctx) = @_;
	my $srch = $ctx->{srch} if $ctx;
	my $rv = "";
	my @title;
	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header('Message-ID');
	$mid = PublicInbox::Hval->new_msgid($mid);
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $header_obj->header($h);
		defined($v) && ($v ne '') or next;
		$v = PublicInbox::Hval->new_oneline($v);

		if ($h eq 'From') {
			my @from = Email::Address->parse($v->raw);
			$title[1] = ascii_html($from[0]->name);
		} elsif ($h eq 'Subject') {
			$title[0] = $v->as_html;
			if ($srch) {
				$rv .= "$h: <b\nid=t>";
				$rv .= $v->as_html . "</b>\n";
				next;
			}
		}
		$rv .= "$h: " . $v->as_html . "\n";

	}
	$rv .= 'Message-ID: &lt;' . $mid->as_html . '&gt; ';
	my $upfx = $full_pfx ? '' : '../';
	$rv .= "(<a\nhref=\"${upfx}raw\">raw</a>)\n";
	my $atom;
	if ($srch) {
		thread_inline(\$rv, $ctx, $mime, $upfx);

		$atom = qq{<link\nrel=alternate\ntitle="Atom feed"\n} .
			qq!href="${upfx}t.atom"\ntype="application/atom+xml"/>!;
	} else {
		$rv .= _parent_headers_nosrch($header_obj);
		$atom = '';
	}
	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) . "</title>$atom".
	 PublicInbox::Hval::STYLE . "</head><body><pre>" . $rv);
}

sub thread_inline {
	my ($dst, $ctx, $cur, $upfx) = @_;
	my $srch = $ctx->{srch};
	my $mid = mid_clean($cur->header('Message-ID'));
	my $res = $srch->get_thread($mid);
	my $nr = $res->{total};
	my $expand = "<a\nhref=\"${upfx}t/#u\">expand</a> " .
			"/ <a\nhref=\"${upfx}t.mbox.gz\">mbox.gz</a>";

	$$dst .= 'Thread: ';
	my $parent = in_reply_to($cur);
	if ($nr <= 1) {
		$$dst .= "[no followups, yet] ($expand)\n";
		$ctx->{next_msg} = undef;
		$ctx->{parent_msg} = $parent;
		return;
	}

	$$dst .= "~$nr messages (<a\nhref=\"#b\">skip</a> / " .
		 $expand . ")\n";

	my $subj = $srch->subject_path($cur->header('Subject'));
	my $state = {
		seen => { $subj => 1 },
		srch => $srch,
		cur => $mid,
		parent_cmp => defined $parent ? $parent : '',
		parent => $parent,
		prev_attr => '',
		prev_level => 0,
	};
	for (thread_results(load_results($res))->rootset) {
		inline_dump($dst, $state, $upfx, $_, 0);
	}
	$$dst .= "<a\nid=b></a>"; # anchor for body start
	$ctx->{next_msg} = $state->{next_msg};
	$ctx->{parent_msg} = $state->{parent};
}

sub _parent_headers_nosrch {
	my ($header_obj) = @_;
	my $rv = '';

	my $irt = in_reply_to($header_obj);
	if (defined $irt) {
		my $v = PublicInbox::Hval->new_msgid($irt, 1);
		my $html = $v->as_html;
		my $href = $v->as_href;
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a\nhref=\"../$href/\">$html</a>&gt;\n";
	}

	my $refs = $header_obj->header('References');
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

sub html_footer {
	my ($mime, $standalone, $full_pfx, $ctx) = @_;
	my %cc; # everyone else
	my $to; # this is the From address

	foreach my $h (qw(From To Cc)) {
		my $v = $mime->header($h);
		defined($v) && ($v ne '') or next;
		my @addrs = Email::Address->parse($v);
		foreach my $recip (@addrs) {
			my $address = $recip->address;
			my $dst = lc($address);
			$cc{$dst} ||= $address;
			$to ||= $dst;
		}
	}
	Email::Address->purge_cache if $standalone;

	my $subj = $mime->header('Subject') || '';
	$subj = "Re: $subj" unless $subj =~ /\bRe:/i;
	my $mid = $mime->header('Message-ID');
	my $irt = uri_escape_utf8($mid);
	delete $cc{$to};
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);

	my $cc = uri_escape_utf8(join(',', sort values %cc));
	my $href = "mailto:$to?In-Reply-To=$irt&Cc=${cc}&Subject=$subj";
	$href =~ s/%20/+/g;

	my $srch = $ctx->{srch} if $ctx;
	my $upfx = $full_pfx ? '../' : '../../';
	my $idx = $standalone ? " <a\nhref=\"$upfx\">index</a>" : '';

	if ($srch && $standalone) {
		$idx .= qq{ / follow: <a\nhref="t.atom">Atom feed</a>\n};
	}
	if ($idx && $srch) {
		my $p = $ctx->{parent_msg};
		my $next = $ctx->{next_msg};
		if ($p) {
			$p = PublicInbox::Hval->new_oneline($p);
			$p = $p->as_href;
			$irt = "<a\nhref=\"$upfx$p/\">parent</a> ";
		} else {
			$irt = ' ' x length('parent ');
		}
		if ($next) {
			$irt .= "<a\nhref=\"$upfx$next/\">next</a> ";
		} else {
			$irt .= ' ' x length('next ');
		}
		if ($p || $next) {
			my $tpfx = $full_pfx ? '' : '../';
			$irt .= "<a\nhref=\"${tpfx}t/#u\">thread</a> ";
		} else {
			$irt .= ' ' x length('thread ');
		}
	} else {
		$irt = '';
	}

	"$irt<a\nhref=\"" . ascii_html($href) . '">reply</a>' . $idx;
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
	my ($cb, $header, $state) = @_;
	$$cb = $$cb->([200, ['Content-Type'=> 'text/html; charset=UTF-8']]);

	my $s = PublicInbox::Hval->new_oneline($header->header('Subject'));
	$s = $s->as_html;
	$$cb->write("<html><head><title>$s</title>".
		qq{<link\nrel=alternate\ntitle="Atom feed"\n} .
		qq!href="../t.atom"\ntype="application/atom+xml"/>! .
		PublicInbox::Hval::STYLE .
		"</head><body>");
}

sub pre_anchor_entry {
	my ($seen, $mime) = @_;
	my $id = anchor_for($mime->header('Message-ID'));
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
	my ($fh, $state, $level) = @_;

	my $max = $state->{cur_level};
	if ($level <= 0) {
		return '' if $max == 0; # flat output

		# reset existing lists
		my $x = $max > 1 ? ('</ul></li>' x ($max - 1)) : '';
		$fh->write($x . '</ul>');
		$state->{cur_level} = 0;
		return '';
	}
	if ($level == $max) { # continue existing list
		$fh->write('<li>');
	} elsif ($level < $max) {
		my $x = $max > 1 ? ('</ul></li>' x ($max - $level)) : '';
		$fh->write($x .= '<li>');
		$state->{cur_level} = $level;
	} else { # ($level > $max) # start a new level
		$state->{cur_level} = $level;
		$fh->write(($max ? '<li>' : '') . '<ul><li>');
	}
	'</li>';
}

sub ghost_flush {
	my ($fh, $state, $upfx, $mid, $level) = @_;

	my $end = thread_adj_level($fh, $state, $level);
	$fh->write('<pre>'. ghost_parent($upfx, $mid) .  '</pre>' . $end);
}

sub __thread_entry {
	my ($cb, $git, $state, $mime, $level) = @_;

	# lazy load the full message from mini_mime:
	$mime = eval {
		my $path = mid2path(mid_clean($mime->header('Message-ID')));
		Email::MIME->new($git->cat_file('HEAD:'.$path));
	} or return;

	if ($state->{anchor_idx} == 0) {
		thread_html_head($cb, $mime, $state, $level);
	}
	my $fh = $$cb;
	if (my $ghost = delete $state->{ghost}) {
		# n.b. ghost messages may only be parents, not children
		foreach my $g (@$ghost) {
			ghost_flush($fh, $state, '../../', @$g);
		}
	}
	my $end = thread_adj_level($fh, $state, $level);
	index_entry($fh, $mime, $level, $state);
	$fh->write($end) if $end;

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
	my ($cb, $git, $state, $node, $level) = @_;
	return unless $node;
	if (my $mime = $node->message) {
		unless (__thread_entry($cb, $git, $state, $mime, $level)) {
			__ghost_prepare($state, $node, $level);
		}
	} else {
		__ghost_prepare($state, $node, $level);
	}

	thread_entry($cb, $git, $state, $node->child, $level + 1);
	thread_entry($cb, $git, $state, $node->next, $level);
}

sub load_results {
	my ($res) = @_;

	[ map { $_->mini_mime } @{delete $res->{msgs}} ];
}

sub msg_timestamp {
	my ($mime) = @_;
	my $ts = eval { str2time($mime->header('Date')) };
	defined($ts) ? $ts : 0;
}

sub thread_results {
	my ($msgs, $nosubject) = @_;
	require PublicInbox::Thread;
	my $th = PublicInbox::Thread->new(@$msgs);
	no warnings 'once';
	$Mail::Thread::nosubject = $nosubject;
	$th->thread;
	$th->order(*sort_ts);
	$th
}

sub missing_thread {
	my ($cb, $ctx) = @_;
	require PublicInbox::ExtMsg;

	$cb->(PublicInbox::ExtMsg::ext_msg($ctx))
}

sub _msg_date {
	my ($mime) = @_;
	my $ts = $mime->header('X-PI-TS') || msg_timestamp($mime);
	fmt_ts($ts);
}

sub fmt_ts { POSIX::strftime('%Y-%m-%d %k:%M', gmtime($_[0])) }

sub _inline_header {
	my ($dst, $state, $upfx, $mime, $level) = @_;
	my $dot = $level == 0 ? '' : '` ';

	my $cur = $state->{cur};
	my $mid = mid_clean($mime->header('Message-ID'));
	my $f = $mime->header('X-PI-From');
	my $d = _msg_date($mime);
	$f = PublicInbox::Hval->new_oneline($f)->as_html;
	$d = PublicInbox::Hval->new_oneline($d)->as_html;
	my $pfx = ' ' . $d . ' ' . indent_for($level);
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
			$$dst .= "$pfx$dot<b><a\nid=r\nhref=\"#b\">".
				 "$attr [this message]</a></b>\n";

			return;
		}
	} else {
		$state->{next_msg} ||= $mid;
	}

	# Subject is never undef, this mail was loaded from
	# our Xapian which would've resulted in '' if it were
	# really missing (and Filter rejects empty subjects)
	my $s = $mime->header('Subject');
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
	if (defined $s) {
		$$dst .= "$pfx$dot<a\nhref=\"$m\">$s</a> $attr\n";
	} else {
		$$dst .= "$pfx$dot<a\nhref=\"$m\">$f</a>\n";
	}
}

sub inline_dump {
	my ($dst, $state, $upfx, $node, $level) = @_;
	return unless $node;
	if (my $mime = $node->message) {
		my $mid = mid_clean($mime->header('Message-ID'));
		if ($mid eq $state->{parent_cmp}) {
			$state->{parent} = $mid;
		}
		_inline_header($dst, $state, $upfx, $mime, $level);
	} else {
		my $dot = $level == 0 ? '' : '` ';
		my $pfx = (' ' x length(' 1970-01-01 13:37 ')).
			indent_for($level) . $dot;
		$$dst .= $pfx;
		$$dst .= ghost_parent("$upfx../", $node->messageid) . "\n";
	}
	inline_dump($dst, $state, $upfx, $node->child, $level+1);
	inline_dump($dst, $state, $upfx, $node->next, $level);
}

sub sort_ts {
	sort {
		(eval { $a->topmost->message->header('X-PI-TS') } || 0) <=>
		(eval { $b->topmost->message->header('X-PI-TS') } || 0)
	} @_;
}

sub rsort_ts {
	sort {
		(eval { $b->topmost->message->header('X-PI-TS') } || 0) <=>
		(eval { $a->topmost->message->header('X-PI-TS') } || 0)
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
		my ($topic, $subj);

		$subj = $x->header('Subject');
		$subj = $state->{srch}->subject_normalized($subj);
		$topic = $subj;

		# kill "[PATCH v2]" etc. for summarization
		unless ($level == 0) {
			$topic =~ s/\A\s*\[[^\]]+\]\s*//g;
		}

		if (++$state->{subjs}->{$topic} == 1) {
			push @{$state->{order}}, [ $level, $subj, $topic ];
		}

		my $mid = mid_clean($x->header('Message-ID'));

		my $ts = $x->header('X-PI-TS');
		my $exist = $state->{latest}->{$topic};
		if (!$exist || $exist->[1] < $ts) {
			$state->{latest}->{$topic} = [ $mid, $ts ];
		}
	} else {
		# ghost message, do not bump level
		$child_adjust = 0;
	}

	add_topic($state, $node->child, $level + $child_adjust);
	add_topic($state, $node->next, $level);
}

sub dump_topics {
	my ($state) = @_;
	my $order = $state->{order};
	my $subjs = $state->{subjs};
	my $latest = $state->{latest};
	return "\n[No topics in range]</pre>" unless (scalar @$order);
	my $dst = '';
	my $pfx;
	my $prev = 0;
	my $prev_attr = '';
	while (defined(my $info = shift @$order)) {
		my ($level, $subj, $topic) = @$info;
		my $n = delete $subjs->{$topic};
		my ($mid, $ts) = @{delete $latest->{$topic}};
		$mid = PublicInbox::Hval->new_msgid($mid)->as_href;
		$subj = PublicInbox::Hval->new($subj)->as_html;
		$pfx = indent_for($level);
		my $nl = $level == $prev ? "\n" : '';
		my $dot = $level == 0 ? '' : '` ';
		$dst .= "$nl$pfx$dot<a\nhref=\"$mid/t/#u\"><b>$subj</b></a>\n";

		my $attr;
		$ts = fmt_ts($ts);
		$attr = " $ts UTC";

		# $n isn't the total number of posts on the topic,
		# just the number of posts in the current results
		# window, so leave it unlabeled
		$n = $n == 1 ? '' : " ($n+ messages)";

		if ($level == 0 || $attr ne $prev_attr) {
			my $mbox = qq(<a\nhref="$mid/t.mbox.gz">mbox.gz</a>);
			my $atom = qq(<a\nhref="$mid/t.atom">Atom</a>);
			$pfx .= INDENT if $level > 0;
			$dst .= $pfx . $attr . $n . " - $mbox / $atom\n";
			$prev_attr = $attr;
		}
	}
	$dst .= '</pre>';
}

sub emit_index_topics {
	my ($state, $fh) = @_;
	my $off = $state->{ctx}->{cgi}->param('o');
	$off = 0 unless defined $off;
	$state->{order} = [];
	$state->{subjs} = {};
	$state->{latest} = {};
	my $max = 25;
	my %opts = ( offset => int $off, limit => $max * 4 );
	while (scalar @{$state->{order}} < $max) {
		my $res = $state->{srch}->query('', \%opts);
		my $nr = scalar @{$res->{msgs}} or last;

		for (rsort_ts(thread_results(load_results($res), 1)->rootset)) {
			add_topic($state, $_, 0);
		}
		$opts{offset} += $nr;
	}

	$fh->write(dump_topics($state));
	$opts{offset};
}

1;
