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
		'</pre><hr />' . PRE_WRAP .
		html_footer($mime, 1, $full_pfx, $srch) . $footer .
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
	my $rv = '';
	my $part_nr = 0;
	my $enc_msg = enc_for($mime->header("Content-Type"));
	my $subj = $mime->header('Subject');
	my $header_obj = $mime->header_obj;

	my $mid_raw = $header_obj->header_raw('Message-ID');
	my $id = anchor_for($mid_raw);
	$seen->{$id} = "#$id"; # save the anchor for later

	my $mid = PublicInbox::Hval->new_msgid($mid_raw);
	my $from = PublicInbox::Hval->new_oneline($mime->header('From'))->raw;
	my @from = Email::Address->parse($from);
	$from = $from[0]->name;
	(defined($from) && length($from)) or $from = $from[0]->address;

	$from = PublicInbox::Hval->new_oneline($from)->as_html;
	$subj = PublicInbox::Hval->new_oneline($subj)->as_html;
	my $pfx = ('  ' x $level);
	my $root_anchor = $seen->{root_anchor};
	my $path;
	my $more = 'permalink';
	if ($root_anchor) {
		$path = '../';
	} else {
		$path = '';
	}
	my $href = $mid->as_href;
	my $irt = $header_obj->header_raw('In-Reply-To');
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
	my $fmt = '%Y-%m-%d %H:%M UTC';
	$ts = POSIX::strftime($fmt, gmtime($ts));

	$rv .= "$pfx<b\nid=\"$id\">$subj</b>\n$pfx";
	$rv .= "- by $from @ $ts - ";
	$rv .= "<a\nid=\"s$midx\"\nhref=\"#s$next\">next</a>";
	if ($prev >= 0) {
		$rv .= "/<a\nhref=\"#s$prev\">prev</a>";
	}
	$rv .= "\n\n";

	my $mhref = "${path}m/$href.html";
	my $fhref = "${path}f/$href.html";
	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		$rv .= index_walk($_[0], $pfx, $enc_msg, $part_nr, $fhref,
				  \$more);
		$part_nr++;
	});
	$mime->body_set('');

	$rv .= "\n$pfx<a\nhref=\"$mhref\">$more</a> ";
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

	$rv . "\n\n";
}

sub thread_html {
	my (undef, $ctx, $foot, $srch) = @_;
	my $mid = mid_compressed($ctx->{mid});
	my $res = $srch->get_thread($mid);
	my $rv = '';
	my $msgs = load_results($ctx, $res);
	my $nr = scalar @$msgs;
	return $rv if $nr == 0;
	require PublicInbox::Thread;
	my $th = PublicInbox::Thread->new(@$msgs);
	$th->thread;
	$th->order(*PublicInbox::Thread::sort_ts);
	my $state = [ $srch, { root_anchor => anchor_for($mid) }, undef, 0 ];
	thread_entry(\$rv, $state, $_, 0) for $th->rootset;
	my $final_anchor = $state->[3];
	my $next = "<a\nid=\"s$final_anchor\">";

	if ($final_anchor == 1) {
		$next .= 'only message in thread';
	} else {
		$next .= 'end of thread';
	}
	$next .= ", back to <a\nhref=\"../\">index</a>\n";

	$rv .= "</pre><hr />" . PRE_WRAP . $next . $foot . "</pre>";
}

sub subject_path_html {
	my (undef, $ctx, $foot, $srch) = @_;
	my $path = $ctx->{subject_path};
	my $res = $srch->get_subject_path($path);
	my $rv = '';
	my $msgs = load_results($ctx, $res);
	my $nr = scalar @$msgs;
	return $rv if $nr == 0;
	require PublicInbox::Thread;
	my $th = PublicInbox::Thread->new(@$msgs);
	$th->thread;
	$th->order(*PublicInbox::Thread::sort_ts);
	my $state = [ $srch, { root_anchor => 'dummy' }, undef, 0 ];
	thread_entry(\$rv, $state, $_, 0) for $th->rootset;
	my $final_anchor = $state->[3];
	my $next = "<a\nid=\"s$final_anchor\">end of thread</a>\n";

	$rv .= "</pre><hr />" . PRE_WRAP . $next . $foot . "</pre>";
}

# only private functions below.

sub index_walk {
	my ($part, $pfx, $enc_msg, $part_nr, $fhref, $more) = @_;
	my $rv = '';
	return $rv if $part->subparts; # walk_parts already recurses
	my $ct = $part->content_type;

	# account for filter bugs...
	return if defined $ct && $ct =~ m!\btext/[xh]+tml\b!i;

	my $enc = enc_for($ct, $enc_msg);

	if ($part_nr > 0) {
		my $fn = $part->filename;
		defined($fn) or $fn = "part #" . ($part_nr + 1);
		$rv .= $pfx . add_filename_line($enc->decode($fn));
	}

	my $s = add_text_body_short($enc, $part, $part_nr, $fhref);

	# drop the remainder of git patches, they're usually better
	# to review when the full message is viewed
	$s =~ s!^---+\n.*\z!!ms and $$more = 'more...';

	# Drop signatures
	$s =~ s/^-- \n.*\z//ms and $$more = 'more...';

	# kill any leading or trailing whitespace lines
	$s =~ s/^\s*$//sgm;
	$s =~ s/\s+\z//s;

	if (length $s) {
		# add prefix:
		$s =~ s/^/$pfx/sgm;

		# kill per-line trailing whitespace
		$s =~ s/[ \t]+$//sgm;

		$rv .= $s . "\n";
	}
	$rv;
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
	my $enc_msg = enc_for($mime->header("Content-Type"));

	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		my $ct = $part->content_type;

		# account for filter bugs...
		return if defined $ct && $ct =~ m!\btext/[xh]+tml\b!i;

		my $enc = enc_for($ct, $enc_msg);

		if ($part_nr > 0) {
			my $fn = $part->filename;
			defined($fn) or $fn = "part #" . ($part_nr + 1);
			$rv .= add_filename_line($enc->decode($fn));
		}

		if (defined $full_pfx) {
			$rv .= add_text_body_short($enc, $part, $part_nr,
						$full_pfx);
		} else {
			$rv .= add_text_body_full($enc, $part, $part_nr);
		}
		$rv .= "\n" unless $rv =~ /\n\z/s;
		++$part_nr;
	});
	$mime->body_set('');
	$rv;
}

sub add_filename_line {
	my ($fn) = @_;
	my $len = 72;
	my $pad = "-";

	$len -= length($fn);
	$pad x= ($len/2) if ($len > 0);
	"$pad " . ascii_html($fn) . " $pad\n";
}

my $LINK_RE = qr!\b((?:ftp|https?|nntp)://[@\w\+\&\?\.\%\;/#=-]+)!;

sub linkify {
	# no newlines added here since it'd break the splitting we do
	# to fold quotes
	$_[0] =~ s!$LINK_RE!<a href="$1">$1</a>!g;
}

sub add_text_body_short {
	my ($enc, $part, $part_nr, $full_pfx) = @_;
	my $n = 0;
	my $s = ascii_html($enc->decode($part->body));
	linkify($s);
	$s =~ s!^((?:(?:&gt;[^\n]*)\n)+)!
		my $cur = $1;
		my @lines = split(/\n/, $cur);
		if (@lines > MAX_INLINE_QUOTED) {
			# show a short snippet of quoted text
			$cur = join(' ', @lines);
			$cur =~ s/^&gt;\s*//;

			my @sum = split(/\s+/, $cur);
			$cur = '';
			do {
				my $tmp = shift(@sum);
				my $len = length($tmp) + length($cur);
				if ($len > MAX_TRUNC_LEN) {
					@sum = ();
				} else {
					$cur .= $tmp . ' ';
				}
			} while (@sum && length($cur) < MAX_TRUNC_LEN);
			$cur =~ s/ \z/ .../;
			"&gt; &lt;<a\nhref=\"${full_pfx}#q${part_nr}_" . $n++ .
				"\">$cur<\/a>&gt;\n";
		} else {
			$cur;
		}
	!emg;
	$s;
}

sub add_text_body_full {
	my ($enc, $part, $part_nr) = @_;
	my $n = 0;
	my $s = ascii_html($enc->decode($part->body));
	linkify($s);
	$s =~ s!^((?:(?:&gt;[^\n]*)\n)+)!
		my $cur = $1;
		my @lines = split(/\n/, $cur);
		if (@lines > MAX_INLINE_QUOTED) {
			"<a\nid=q${part_nr}_" . $n++ . ">$cur</a>";
		} else {
			$cur;
		}
	!emg;
	$s;
}

sub headers_to_html_header {
	my ($mime, $full_pfx, $srch) = @_;

	my $rv = "";
	my @title;
	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header_raw('Message-ID');
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

	my $irt = $header_obj->header_raw('In-Reply-To');
	if (defined $irt) {
		my $v = PublicInbox::Hval->new_msgid($irt);
		my $html = $v->as_html;
		my $href = $v->as_href;
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a\nhref=\"$href.html\">$html</a>&gt;\n";
	}

	my $refs = $header_obj->header_raw('References');
	if ($refs) {
		$refs =~ s/\s*\Q$irt\E\s*// if (defined $irt);
		my @refs = ($refs =~ /<([^>]+)>/g);
		if (@refs) {
			$rv .= 'References: '. linkify_refs(@refs) . "\n";
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
	my $mid = $mime->header_obj->header_raw('Message-ID');
	my $irt = uri_escape_utf8($mid);
	delete $cc{$to};
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);

	my $cc = uri_escape_utf8(join(',', sort values %cc));
	my $href = "mailto:$to?In-Reply-To=$irt&Cc=${cc}&Subject=$subj";

	my $idx = $standalone ? " <a\nhref=\"../\">index</a>" : '';
	if ($idx && $srch) {
		$irt = $mime->header_obj->header_raw('In-Reply-To') || '';
		$mid = mid_compressed(mid_clean($mid));
		my $t_anchor = length $irt ? T_ANCHOR : '';
		$idx = " <a\nhref=\"../t/$mid.html$t_anchor\">".
		       "threadlink</a>$idx";
		my $res = $srch->get_followups($mid);
		if (my $c = $res->{count}) {
			$c = $c == 1 ? '1 followup' : "$c followups";
			$idx .= "\n$c:\n";
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

sub linkify_refs {
	join(' ', map {
		my $v = PublicInbox::Hval->new_msgid($_);
		my $html = $v->as_html;
		my $href = $v->as_href;
		"&lt;<a\nhref=\"$href.html\">$html</a>&gt;";
	} @_);
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
	my $pfx = '  ' x $level;
	$$dst .= $pfx;
	if (my $x = $node->message) {
		my $mid = $x->header('Message-ID');
		if ($root->[0] ne $mid) {
			my $s = $x->header('Subject');
			my $h = hash_subj($s);
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
	simple_dump($dst, $root, $node->child, $level + 1) if $node->child;
	simple_dump($dst, $root, $node->next, $level) if $node->next;
}

sub hash_subj {
	my ($subj) = @_;
	$subj =~ s/\A\s+//;
	$subj =~ s/\s+\z//;
	$subj =~ s/^(?:re|aw):\s*//i; # remove reply prefix (aw: German)
	$subj =~ s/\s+/ /;
	Digest::SHA::sha1($subj);
}

sub thread_followups {
	my ($dst, $root, $res) = @_;
	my @msgs = map { $_->mini_mime } @{$res->{msgs}};
	require PublicInbox::Thread;
	$root->header_set('X-PI-TS', '0');
	my $th = PublicInbox::Thread->new($root, @msgs);
	$th->thread;
	$th->order(*PublicInbox::Thread::sort_ts);
	$root = [ $root->header('Message-ID'),
		  { hash_subj($root->header('Subject')) => 1 } ];
	simple_dump($dst, $root, $_, 0) for $th->rootset;
}

sub thread_html_head {
	my ($mime) = @_;
	my $s = PublicInbox::Hval->new_oneline($mime->header('Subject'));
	$s = $s->as_html;
	"<html><head><title>$s</title></head><body>" . PRE_WRAP

}

sub thread_entry {
	my ($dst, $state, $node, $level) = @_;
	# $state = [ $search_res, $seen, undef, 0 (msg_nr) ];
	# $seen is overloaded with 3 types of fields:
	#	1) "root_anchor" => anchor_for(Message-ID),
	#	2) seen subject hashes: sha1(subject) => 1
	#	3) anchors hashes: "#$sha1_hex" (same as $seen in index_entry)
	if (my $mime = $node->message) {
		if (length($$dst) == 0) {
			$$dst .= thread_html_head($mime);
		}
		$$dst .= index_entry(undef, $mime, $level, $state);
	}
	thread_entry($dst, $state, $node->child, $level + 1) if $node->child;
	thread_entry($dst, $state, $node->next, $level) if $node->next;
}

sub load_results {
	my ($ctx, $res) = @_;

	require PublicInbox::GitCatFile;
	my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});
	my @msgs;
	while (my $smsg = shift @{$res->{msgs}}) {
		my $m = $smsg->mid;
		my $path = mid2path($m);

		# FIXME: duplicated code from Feed.pm
		my $mime = eval {
			my $str = $git->cat_file("HEAD:$path");
			Email::MIME->new($str);
		};
		unless ($@) {
			my $t = eval { str2time($mime->header('Date')) };
			defined($t) or $t = 0;
			$mime->header_set('X-PI-TS', $t);
			push @msgs, $mime;
		}
	}
	\@msgs;
}

1;
