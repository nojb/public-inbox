# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::View;
use strict;
use warnings;
use URI::Escape qw/uri_escape_utf8/;
use Date::Parse qw/str2time/;
use Encode qw/find_encoding/;
use Encode::MIME::Header;
use Email::MIME::ContentType qw/parse_content_type/;
use PublicInbox::Hval;
use PublicInbox::MID qw/mid_clean mid_compressed mid2path/;
use Digest::SHA;
require POSIX;

# TODO: make these constants tunable
use constant MAX_INLINE_QUOTED => 12; # half an 80x24 terminal
use constant MAX_TRUNC_LEN => 72;
use constant PRE_WRAP => "<pre\nstyle=\"white-space:pre-wrap\">";
use constant T_ANCHOR => '#u';

*ascii_html = *PublicInbox::Hval::ascii_html;

my $enc_utf8 = find_encoding('UTF-8');

# public functions:
sub msg_html {
	my ($class, $mime, $full_pfx, $footer, $srch) = @_;
	if (defined $footer) {
		$footer = "\n" . $footer;
	} else {
		$footer = '';
	}
	headers_to_html_header($mime, $full_pfx, $srch) .
		multipart_text_as_html($mime, $full_pfx) .
		'</pre><hr /><pre>' .
		html_footer($mime, 1, $full_pfx, $srch) .
		$footer .
		'</pre></body></html>';
}

sub feed_entry {
	my ($class, $mime, $full_pfx) = @_;

	PRE_WRAP . multipart_text_as_html($mime, $full_pfx) . '</pre>';
}

# this is already inside a <pre>
# state = [ time, seen = {}, first_commit, page_nr = 0 ]
sub index_entry {
	my (undef, $mime, $level, $state) = @_;
	my ($srch, $seen, $first_commit) = @$state;
	my $midx = $state->[3]++;
	my ($prev, $next) = ($midx - 1, $midx + 1);
	my $part_nr = 0;
	my $enc = enc_for($mime->header("Content-Type"));
	my $subj = $mime->header('Subject');
	my $header_obj = $mime->header_obj;

	my $mid_raw = $header_obj->header('Message-ID');
	my $id = anchor_for($mid_raw);
	$seen->{$id} = "#$id"; # save the anchor for later

	my $mid = PublicInbox::Hval->new_msgid($mid_raw);
	my $from = PublicInbox::Hval->new_oneline($mime->header('From'))->raw;
	my @from = Email::Address->parse($from);
	$from = $from[0]->name;
	(defined($from) && length($from)) or $from = $from[0]->address;

	$from = PublicInbox::Hval->new_oneline($from)->as_html;
	$subj = PublicInbox::Hval->new_oneline($subj)->as_html;
	my $root_anchor = $seen->{root_anchor};
	my $more = 'permalink';
	my $path = $root_anchor ? '../' : '';
	my $href = $mid->as_href;
	my $irt = $header_obj->header('In-Reply-To');
	my ($anchor_idx, $anchor, $t_anchor);
	if (defined $irt) {
		$anchor_idx = anchor_for($irt);
		$anchor = $seen->{$anchor_idx};
		$t_anchor = T_ANCHOR;
	} else {
		$t_anchor = '';
	}
	if (defined $srch) {
		$subj = "<a\nhref=\"${path}t/$href.html#u\">$subj</a>";
	}
	if ($root_anchor && $root_anchor eq $id) {
		$subj = "<u\nid=\"u\">$subj</u>";
	}

	my $ts = $mime->header('X-PI-TS');
	unless (defined $ts) {
		$ts = msg_timestamp($mime);
	}
	my $fmt = '%Y-%m-%d %H:%M';
	$ts = POSIX::strftime($fmt, gmtime($ts));

	my $rv = "<table\nsummary=l$level><tr>";
	if ($level) {
		$rv .= '<td><pre>' . ('  ' x $level) . '</pre></td>';
	}
	$rv .= "<td\nid=s$midx>" . PRE_WRAP;
	$rv .= "<b\nid=\"$id\">$subj</b>\n";
	$rv .= "- by $from @ $ts UTC - ";
	$rv .= "<a\nhref=\"#s$next\">next</a>";
	if ($prev >= 0) {
		$rv .= "/<a\nhref=\"#s$prev\">prev</a>";
	}
	$rv .= "\n\n";

	my ($fhref, $more_ref);
	my $mhref = "${path}m/$href.html";
	if ($level > 0) {
		$fhref = "${path}f/$href.html";
		$more_ref = \$more;
	}
	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		$rv .= index_walk($_[0], $enc, \$part_nr, $fhref, $more_ref);
	});
	$mime->body_set('');

	$rv .= "\n<a\nhref=\"$mhref\">$more</a> ";
	my $txt = "${path}m/$href.txt";
	$rv .= "<a\nhref=\"$txt\">raw</a> ";
	$rv .= html_footer($mime, 0);

	if (defined $irt) {
		unless (defined $anchor) {
			my $v = PublicInbox::Hval->new_msgid($irt);
			$v = $v->as_href;
			$anchor = "${path}m/$v.html";
			$seen->{$anchor_idx} = $anchor;
		}
		$rv .= " <a\nhref=\"$anchor\">parent</a>";
	}

	if ($srch) {
		$rv .= " <a\nhref=\"${path}t/$href.html$t_anchor\">" .
		       "threadlink</a>";
	}

	$rv .= '</pre></td></tr></table>';
}

sub thread_html {
	my (undef, $ctx, $foot, $srch) = @_;
	my $mid = mid_compressed($ctx->{mid});
	my $res = $srch->get_thread($mid);
	my $rv = '';
	my $msgs = load_results($res);
	my $nr = scalar @$msgs;
	return $rv if $nr == 0;
	my $th = thread_results($msgs);
	my $state = [ $srch, { root_anchor => anchor_for($mid) }, undef, 0 ];
	{
		require PublicInbox::GitCatFile;
		my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});
		thread_entry(\$rv, $git, $state, $_, 0) for $th->rootset;
	}
	my $final_anchor = $state->[3];
	my $next = "<a\nid=\"s$final_anchor\">";

	if ($final_anchor == 1) {
		$next .= 'only message in thread';
	} else {
		$next .= 'end of thread';
	}
	$next .= "</a>, back to <a\nhref=\"../\">index</a>\n";

	$rv .= "<hr />" . PRE_WRAP . $next . $foot . "</pre>";
}

# only private functions below.

sub index_walk {
	my ($part, $enc, $part_nr, $fhref, $more) = @_;
	my $s = add_text_body($enc, $part, $part_nr, $fhref);

	if ($more) {
		# drop the remainder of git patches, they're usually better
		# to review when the full message is viewed
		$s =~ s!^---+\n.*\z!!ms and $$more = 'more...';

		# Drop signatures
		$s =~ s/^-- \n.*\z//ms and $$more = 'more...';
	}

	# kill any leading or trailing whitespace lines
	$s =~ s/^\s*$//sgm;
	$s =~ s/\s+\z//s;

	if (length $s) {
		# kill per-line trailing whitespace
		$s =~ s/[ \t]+$//sgm;
		$s .= "\n" unless $s =~ /\n\z/s;
	}
	$s;
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
		$rv .= add_text_body($enc, $part, \$part_nr, $full_pfx);
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

my $LINK_RE = qr!\b((?:ftp|https?|nntp)://[@\w\+\&\?\.\%\;/#=-]+)!;

sub linkify {
	# no newlines added here since it'd break the splitting we do
	# to fold quotes
	$_[0] =~ s!$LINK_RE!<a\nhref="$1">$1</a>!g;
}

sub flush_quote {
	my ($quot, $n, $part_nr, $full_pfx, $final) = @_;

	if ($full_pfx) {
		if (!$final && scalar(@$quot) <= MAX_INLINE_QUOTED) {
			# show quote inline
			my $rv = join("\n", map { linkify($_); $_ } @$quot);
			@$quot = ();
			return $rv . "\n";
		}

		# show a short snippet of quoted text and link to full version:
		@$quot = map { s/^(?:&gt;\s*)+//gm; $_ } @$quot;
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
		my $nr = ++$$n;
		"&gt; [<a\nhref=\"$full_pfx#q${part_nr}_$nr\">$cur</a>]\n";
	} else {
		# show everything in the full version with anchor from
		# short version (see above)
		my $nr = ++$$n;
		my $rv = "<a\nid=q${part_nr}_$nr></a>";
		$rv .= join("\n", map { linkify($_); $_ } @$quot) . "\n";
		@$quot = ();
		$rv;
	}
}

sub add_text_body {
	my ($enc_msg, $part, $part_nr, $full_pfx) = @_;
	return '' if $part->subparts;

	my $ct = $part->content_type;
	# account for filter bugs...
	if (defined $ct && $ct =~ m!\btext/[xh]+tml\b!i) {
		$part->body_set('');
		return '';
	}
	my $enc = enc_for($ct, $enc_msg);
	my $n = 0;
	my $nr = 0;
	my $s = $part->body;
	$part->body_set('');
	$s = $enc->decode($s);
	$s = ascii_html($s);
	my @lines = split(/\n/, $s);
	$s = '';

	if ($$part_nr > 0) {
		my $fn = $part->filename;
		defined($fn) or $fn = "part #" . ($$part_nr + 1);
		$s .= add_filename_line($enc, $fn);
	}

	my @quot;
	while (defined(my $cur = shift @lines)) {
		if ($cur !~ /^&gt;/) {
			# show the previously buffered quote inline
			if (scalar @quot) {
				$s .= flush_quote(\@quot, \$n, $$part_nr,
						  $full_pfx, 0);
			}

			# regular line, OK
			linkify($cur);
			$s .= $cur;
			$s .= "\n";
		} else {
			push @quot, $cur;
		}
	}
	$s .= flush_quote(\@quot, \$n, $$part_nr, $full_pfx, 1) if scalar @quot;
	$s .= "\n" unless $s =~ /\n\z/s;
	++$$part_nr;
	$s;
}

sub headers_to_html_header {
	my ($mime, $full_pfx, $srch) = @_;

	my $rv = "";
	my @title;
	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header('Message-ID');
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $mid_href = $mid->as_href;
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $mime->header($h);
		defined($v) && length($v) or next;
		$v = PublicInbox::Hval->new_oneline($v);

		if ($h eq 'From') {
			my @from = Email::Address->parse($v->raw);
			$title[1] = ascii_html($from[0]->name);
		} elsif ($h eq 'Subject') {
			$title[0] = $v->as_html;
			if ($srch) {
				$rv .= "$h: <a\nhref=\"../t/$mid_href.html\">";
				$rv .= $v->as_html . "</a>\n";
				next;
			}
		}
		$rv .= "$h: " . $v->as_html . "\n";

	}

	$rv .= 'Message-ID: &lt;' . $mid->as_html . '&gt; ';
	$mid_href = "../m/$mid_href" unless $full_pfx;
	$rv .= "(<a\nhref=\"$mid_href.txt\">raw</a>)\n";

	my $irt = $header_obj->header('In-Reply-To');
	if (defined $irt) {
		my $v = PublicInbox::Hval->new_msgid($irt);
		my $html = $v->as_html;
		my $href = $v->as_href;
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a\nhref=\"$href.html\">$html</a>&gt;\n";
	}

	my $refs = $header_obj->header('References');
	if ($refs) {
		# avoid redundant URLs wasting bandwidth
		my %seen;
		$seen{mid_clean($irt)} = 1 if defined $irt;
		my @refs;
		my @raw_refs = ($refs =~ /<([^>]+)>/g);
		foreach my $ref (@raw_refs) {
			next if $seen{$ref};
			$seen{$ref} = 1;
			push @refs, linkify_ref($ref);
		}

		if (@refs) {
			$rv .= 'References: '. join(' ', @refs) . "\n";
		}
	}

	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) .
	 '</title></head><body>' . PRE_WRAP . $rv);
}

sub html_footer {
	my ($mime, $standalone, $full_pfx, $srch) = @_;
	my %cc; # everyone else
	my $to; # this is the From address

	foreach my $h (qw(From To Cc)) {
		my $v = $mime->header($h);
		defined($v) && length($v) or next;
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
	$subj = "Re: $subj" unless $subj =~ /\bRe:/;
	my $mid = $mime->header_obj->header('Message-ID');
	my $irt = uri_escape_utf8($mid);
	delete $cc{$to};
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);

	my $cc = uri_escape_utf8(join(',', sort values %cc));
	my $href = "mailto:$to?In-Reply-To=$irt&Cc=${cc}&Subject=$subj";

	my $idx = $standalone ? " <a\nhref=\"../\">index</a>" : '';
	if ($idx && $srch) {
		$irt = $mime->header_obj->header('In-Reply-To') || '';
		$mid = mid_compressed(mid_clean($mid));
		my $t_anchor = length $irt ? T_ANCHOR : '';
		$idx = " <a\nhref=\"../t/$mid.html$t_anchor\">".
		       "threadlink</a>$idx";
		my $res = $srch->get_followups($mid);
		if (my $c = $res->{total}) {
			$c = $c == 1 ? '1 followup' : "$c followups";
			$idx .= "\n$c:\n";
			$res->{srch} = $srch;
			thread_followups(\$idx, $mime, $res);
		} else {
			$idx .= "\n(no followups, yet)\n";
		}
		if ($irt) {
			$irt = PublicInbox::Hval->new_msgid($irt);
			$irt = $irt->as_href;
			$irt = "<a\nhref=\"$irt\">parent</a> ";
		} else {
			$irt = ' ' x length('parent ');
		}
	} else {
		$irt = '';
	}

	"$irt<a\nhref=\"" . ascii_html($href) . '">reply</a>' . $idx;
}

sub linkify_ref {
	my $v = PublicInbox::Hval->new_msgid($_[0]);
	my $html = $v->as_html;
	my $href = $v->as_href;
	"&lt;<a\nhref=\"$href.html\">$html</a>&gt;";
}

sub anchor_for {
	my ($msgid) = @_;
	my $id = $msgid;
	if ($id !~ /\A[a-f0-9]{40}\z/) {
		$id = mid_compressed(mid_clean($id), 1);
	}
	'm' . $id;
}

sub simple_dump {
	my ($dst, $root, $node, $level) = @_;
	return unless $node;
	# $root = [ Root Message-ID, \%seen, $srch ];
	if (my $x = $node->message) {
		my $mid = $x->header('Message-ID');
		if ($root->[0] ne $mid) {
			my $pfx = '  ' x $level;
			$$dst .= $pfx;
			my $s = $x->header('Subject');
			my $h = $root->[2]->subject_path($s);
			if ($root->[1]->{$h}) {
				$s = '';
			} else {
				$root->[1]->{$h} = 1;
				$s = PublicInbox::Hval->new($s);
				$s = $s->as_html;
			}
			my $m = PublicInbox::Hval->new_msgid($mid);
			my $f = PublicInbox::Hval->new($x->header('X-PI-From'));
			my $d = PublicInbox::Hval->new($x->header('X-PI-Date'));
			$m = $m->as_href . '.html';
			$f = $f->as_html;
			$d = $d->as_html . ' UTC';
			if (length($s) == 0) {
				$$dst .= "` <a\nhref=\"$m\">$f @ $d</a>\n";
			} else {
				$$dst .= "` <a\nhref=\"$m\">$s</a>\n" .
				     "$pfx  by $f @ $d\n";
			}
		}
	}
	simple_dump($dst, $root, $node->child, $level+1);
	simple_dump($dst, $root, $node->next, $level);
}

sub thread_followups {
	my ($dst, $root, $res) = @_;
	$root->header_set('X-PI-TS', '0');
	my $msgs = load_results($res);
	push @$msgs, $root;
	my $th = thread_results($msgs);
	my $srch = $res->{srch};
	my $subj = $srch->subject_path($root->header('Subject'));
	my %seen = ($subj => 1);
	$root = [ $root->header('Message-ID'), \%seen, $srch ];
	simple_dump($dst, $root, $_, 0) for $th->rootset;
}

sub thread_html_head {
	my ($mime) = @_;
	my $s = PublicInbox::Hval->new_oneline($mime->header('Subject'));
	$s = $s->as_html;
	"<html><head><title>$s</title></head><body>";
}

sub thread_entry {
	my ($dst, $git, $state, $node, $level) = @_;
	return unless $node;
	# $state = [ $search_res, $seen, undef, 0 (msg_nr) ];
	# $seen is overloaded with 3 types of fields:
	#	1) "root_anchor" => anchor_for(Message-ID),
	#	2) seen subject hashes: sha1(subject) => 1
	#	3) anchors hashes: "#$sha1_hex" (same as $seen in index_entry)
	if (my $mime = $node->message) {

		# lazy load the full message from mini_mime:
		my $path = mid2path(mid_clean($mime->header('Message-ID')));
		$mime = eval { Email::MIME->new($git->cat_file("HEAD:$path")) };
		if ($mime) {
			if (length($$dst) == 0) {
				$$dst .= thread_html_head($mime);
			}
			$$dst .= index_entry(undef, $mime, $level, $state);
		}
	}
	thread_entry($dst, $git, $state, $node->child, $level + 1);
	thread_entry($dst, $git, $state, $node->next, $level);
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
	my ($msgs) = @_;
	require PublicInbox::Thread;
	my $th = PublicInbox::Thread->new(@$msgs);
	$th->thread;
	$th->order(*PublicInbox::Thread::sort_ts);
	$th
}

1;
