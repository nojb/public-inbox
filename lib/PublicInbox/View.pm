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
use PublicInbox::MID qw/mid_clean mid_compress mid2path/;
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
	my ($ctx, $mime, $full_pfx, $footer) = @_;
	if (defined $footer) {
		$footer = "\n" . $footer;
	} else {
		$footer = '';
	}
	headers_to_html_header($mime, $full_pfx, $ctx) .
		multipart_text_as_html($mime, $full_pfx) .
		'</pre><hr />' . PRE_WRAP .
		html_footer($mime, 1, $full_pfx, $ctx) .
		$footer .
		'</pre></body></html>';
}

sub feed_entry {
	my ($class, $mime, $full_pfx) = @_;

	PRE_WRAP . multipart_text_as_html($mime, $full_pfx) . '</pre>';
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

	my $mid_raw = $header_obj->header('Message-ID');
	my $id = anchor_for($mid_raw);
	my $seen = $state->{seen};
	$seen->{$id} = "#$id"; # save the anchor for later

	my $mid = PublicInbox::Hval->new_msgid($mid_raw);
	my $from = PublicInbox::Hval->new_oneline($mime->header('From'))->raw;
	my @from = Email::Address->parse($from);
	$from = $from[0]->name;

	$from = PublicInbox::Hval->new_oneline($from)->as_html;
	$subj = PublicInbox::Hval->new_oneline($subj)->as_html;
	my $more = 'permalink';
	my $root_anchor = $state->{root_anchor};
	my $path = $root_anchor ? '../../' : '';
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
	if ($srch) {
		$subj = "<a\nhref=\"${path}t/$href/#u\">$subj</a>";
	}
	if ($root_anchor && $root_anchor eq $id) {
		$subj = "<u\nid=\"u\">$subj</u>";
	}

	my $ts = $mime->header('X-PI-TS');
	unless (defined $ts) {
		$ts = msg_timestamp($mime);
	}
	$ts = POSIX::strftime('%Y-%m-%d %H:%M', gmtime($ts));

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
	$fh->write($rv .= "\n\n");

	my ($fhref, $more_ref);
	my $mhref = "${path}m/$href/";
	if ($level > 0) {
		$fhref = "${path}f/$href/";
		$more_ref = \$more;
	}
	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		index_walk($fh, $_[0], $enc, \$part_nr, $fhref, $more_ref);
	});
	$mime->body_set('');

	my $txt = "${path}m/$href/raw";
	$rv = "\n<a\nhref=\"$mhref\">$more</a> <a\nhref=\"$txt\">raw</a> ";
	$rv .= html_footer($mime, 0, undef, $ctx);

	if (defined $irt) {
		unless (defined $anchor) {
			my $v = PublicInbox::Hval->new_msgid($irt);
			$v = $v->as_href;
			$anchor = "${path}m/$v/";
			$seen->{$anchor_idx} = $anchor;
		}
		$rv .= " <a\nhref=\"$anchor\">parent</a>";
	}

	if ($srch) {
		$rv .= " <a\nhref=\"${path}t/$href/$t_anchor\">" .
		       "threadlink</a>";
	}

	$fh->write($rv .= '</pre></td></tr></table>');
}

sub thread_html {
	my ($ctx, $foot, $srch) = @_;
	sub { emit_thread_html($_[0], $ctx, $foot, $srch) }
}

# only private functions below.

sub emit_thread_html {
	my ($cb, $ctx, $foot, $srch) = @_;
	my $mid = mid_compress($ctx->{mid});
	my $res = $srch->get_thread($mid);
	my $msgs = load_results($res);
	my $nr = scalar @$msgs;
	return missing_thread($cb) if $nr == 0;
	my $fh = $cb->([200,['Content-Type'=>'text/html; charset=UTF-8']]);
	my $th = thread_results($msgs);
	my $state = {
		ctx => $ctx,
		seen => {},
		root_anchor => anchor_for($mid),
		anchor_idx => 0,
	};
	{
		require PublicInbox::GitCatFile;
		my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});
		thread_entry($fh, $git, $state, $_, 0) for $th->rootset;
	}
	my $final_anchor = $state->{anchor_idx};
	my $next = "<a\nid=\"s$final_anchor\">";
	$next .= $final_anchor == 1 ? 'only message in' : 'end of';
	$next .= " thread</a>, back to <a\nhref=\"../../\">index</a>\n";
	$next .= "download: <a\nhref=\"mbox.gz\">mbox.gz</a>\n\n";
	$fh->write("<hr />" . PRE_WRAP . $next . $foot .
		   "</pre></body></html>");
	$fh->close;
}

sub index_walk {
	my ($fh, $part, $enc, $part_nr, $fhref, $more) = @_;
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

my $LINK_RE = qr!\b((?:ftp|https?|nntp)://
		 [\@:\w\.-]+/
		 ?[\@\w\+\&\?\.\%\;/#=-]*)!x;

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
			my $rv = join('', map { linkify($_); $_ } @$quot);
			@$quot = ();
			return $rv;
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
		$rv .= join('', map { linkify($_); $_ } @$quot);
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
	my @lines = split(/^/m, $s);
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
	my ($mime, $full_pfx, $ctx) = @_;
	my $srch = $ctx->{srch} if $ctx;
	my $rv = "";
	my @title;
	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header('Message-ID');
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $mid_href = $mid->as_href;
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $mime->header($h);
		defined($v) && ($v ne '') or next;
		$v = PublicInbox::Hval->new_oneline($v);

		if ($h eq 'From') {
			my @from = Email::Address->parse($v->raw);
			$title[1] = ascii_html($from[0]->name);
		} elsif ($h eq 'Subject') {
			$title[0] = $v->as_html;
			if ($srch) {
				$rv .= "$h: <a\nid=\"t\"\n" .
					"href=\"../../t/$mid_href/\">";
				$rv .= $v->as_html . "</a>\n";
				next;
			}
		}
		$rv .= "$h: " . $v->as_html . "\n";

	}
	$rv .= 'Message-ID: &lt;' . $mid->as_html . '&gt; ';
	my $raw_ref = $full_pfx ? 'raw' : "../../m/$mid_href/raw";
	$rv .= "(<a\nhref=\"$raw_ref\">raw</a>)\n";
	if ($srch) {
		$rv .= "<a\nhref=\"#r\">References: [see below]</a>\n";
	} else {
		$rv .= _parent_headers_nosrch($header_obj);
	}
	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) .
	 '</title></head><body>' . PRE_WRAP . $rv);
}

sub thread_inline {
	my ($dst, $ctx, $cur) = @_;
	my $srch = $ctx->{srch};
	my $mid = mid_compress(mid_clean($cur->header('Message-ID')));
	my $res = $srch->get_thread($mid);
	my $nr = $res->{total};

	if ($nr <= 1) {
		$$dst .= "\n[no followups, yet]</a>\n";
		return;
	}

	$$dst .= "\n\n~$nr messages in thread: ".
		 "(<a\nhref=\"../../t/$mid/#u\">expand</a>)\n";
	my $subj = $srch->subject_path($cur->header('Subject'));
	my $state = {
		seen => { $subj => 1 },
		srch => $srch,
		cur => $mid,
	};
	for (thread_results(load_results($res))->rootset) {
		inline_dump($dst, $state, $_, 0);
	}
	$state->{next_msg};
}

sub _parent_headers_nosrch {
	my ($header_obj) = @_;
	my $rv = '';

	my $irt = $header_obj->header('In-Reply-To');
	if (defined $irt) {
		my $v = PublicInbox::Hval->new_msgid($irt);
		my $html = $v->as_html;
		my $href = $v->as_href;
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a\nhref=\"../$href/\">$html</a>&gt;\n";
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

	my $srch = $ctx->{srch} if $ctx;
	my $idx = $standalone ? " <a\nhref=\"../../\">index</a>" : '';
	if ($idx && $srch) {
		my $next = thread_inline(\$idx, $ctx, $mime);
		if (defined $irt) {
			$irt = PublicInbox::Hval->new_msgid($irt);
			$irt = $irt->as_href;
			$irt = "<a\nhref=\"../$irt/\">parent</a> ";
		} else {
			$irt = ' ' x length('parent ');
		}
		if ($next) {
			$irt .= "<a\nhref=\"../$next/\">next</a> ";
		} else {
			$irt .= '     ';
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
	"&lt;<a\nhref=\"../$href/\">$html</a>&gt;";
}

sub anchor_for {
	my ($msgid) = @_;
	my $id = $msgid;
	if ($id !~ /\A[a-f0-9]{40}\z/) {
		$id = mid_compress(mid_clean($id), 1);
	}
	'm' . $id;
}

sub thread_html_head {
	my ($mime) = @_;
	my $s = PublicInbox::Hval->new_oneline($mime->header('Subject'));
	$s = $s->as_html;
	"<html><head><title>$s</title></head><body>";
}

sub thread_entry {
	my ($fh, $git, $state, $node, $level) = @_;
	return unless $node;
	if (my $mime = $node->message) {

		# lazy load the full message from mini_mime:
		my $path = mid2path(mid_clean($mime->header('Message-ID')));
		$mime = eval { Email::MIME->new($git->cat_file("HEAD:$path")) };
		if ($mime) {
			if ($state->{anchor_idx} == 0) {
				$fh->write(thread_html_head($mime));
			}
			index_entry($fh, $mime, $level, $state);
		}
	}
	thread_entry($fh, $git, $state, $node->child, $level + 1);
	thread_entry($fh, $git, $state, $node->next, $level);
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
	no warnings 'once';
	$th->order(*PublicInbox::Thread::sort_ts);
	$th
}

sub missing_thread {
	my ($cb) = @_;
	my $title = 'Thread does not exist';
	$cb->([404, ['Content-Type' => 'text/html']])->write(<<EOF);
<html><head><title>$title</title></head><body><pre>$title
<a href="../../">Return to index</a></pre></body></html>
EOF
}

sub _inline_header {
	my ($dst, $state, $mime, $level) = @_;
	my $pfx = '  ' x $level;

	my $cur = $state->{cur};
	my $mid = $mime->header('Message-ID');
	my $f = $mime->header('X-PI-From');
	my $d = $mime->header('X-PI-Date');
	$f = PublicInbox::Hval->new($f);
	$d = PublicInbox::Hval->new($d);
	$f = $f->as_html;
	$d = $d->as_html . ' UTC';
	my $midc = mid_compress(mid_clean($mid));
	if ($cur) {
		if ($cur eq $midc) {
			delete $state->{cur};
			$$dst .= "$pfx` <b><a\nid=\"r\"\nhref=\"#t\">".
				 "[this message]</a></b> by $f @ $d\n";

			return;
		}
	} else {
		$state->{next_msg} ||= $midc;
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
	$m = '../' . $m->as_href . '/';
	if (defined $s) {
		$$dst .= "$pfx` <a\nhref=\"$m\">$s</a>\n" .
		         "$pfx  $f @ $d\n";
	} else {
		$$dst .= "$pfx` <a\nhref=\"$m\">$f @ $d</a>\n";
	}
}

sub inline_dump {
	my ($dst, $state, $node, $level) = @_;
	return unless $node;
	return if $state->{stopped};
	if (my $mime = $node->message) {
		_inline_header($dst, $state, $mime, $level);
	}
	inline_dump($dst, $state, $node->child, $level+1);
	inline_dump($dst, $state, $node->next, $level);
}

1;
