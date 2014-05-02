# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::View;
use strict;
use warnings;
use PublicInbox::Hval;
use URI::Escape qw/uri_escape_utf8/;
use Encode qw/find_encoding/;
use Encode::MIME::Header;
use Email::MIME::ContentType qw/parse_content_type/;
use constant MAX_INLINE_QUOTED => 5;
use constant MAX_TRUNC_LEN => 72;
*ascii_html = *PublicInbox::Hval::ascii_html;

my $enc_utf8 = find_encoding('UTF-8');
my $enc_mime = find_encoding('MIME-Header');

# public functions:
sub msg_html {
	my ($class, $mime, $full_pfx) = @_;

	headers_to_html_header($mime, $full_pfx) .
		multipart_text_as_html($mime, $full_pfx) .
		'</pre><hr /><pre>' .
		html_footer($mime) .
		'</pre></body></html>';
}

sub feed_entry {
	my ($class, $mime, $full_pfx) = @_;

	'<pre>' . multipart_text_as_html($mime, $full_pfx) . '</pre>';
}


# only private functions below.

sub enc_for {
	my ($ct) = @_;
	defined $ct or return $enc_utf8;
	my $ct_parsed = parse_content_type($ct);
	if ($ct_parsed) {
		if (my $charset = $ct_parsed->{attributes}->{charset}) {
			my $enc = find_encoding($charset);
			return $enc if $enc;
		}
	}
	$enc_utf8;
}

sub multipart_text_as_html {
	my ($mime, $full_pfx) = @_;
	my $rv = "";
	my $part_nr = 0;
	my $enc_msg = enc_for($mime->header("Content-Type"));

	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		my $enc = enc_for($part->content_type) || $enc_msg || $enc_utf8;

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

sub add_text_body_short {
	my ($enc, $part, $part_nr, $full_pfx) = @_;
	my $n = 0;
	my $s = ascii_html($enc->decode($part->body));
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
			"&gt; &lt;<a href=\"${full_pfx}#q${part_nr}_" . $n++ .
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
	$s =~ s!^((?:(?:&gt;[^\n]*)\n)+)!
		my $cur = $1;
		my @lines = split(/\n/, $cur);
		if (@lines > MAX_INLINE_QUOTED) {
			"<a name=q${part_nr}_" . $n++ . ">$cur</a>";
		} else {
			$cur;
		}
	!emg;
	$s;
}

sub headers_to_html_header {
	my ($mime, $full_pfx) = @_;

	my $rv = "";
	my @title;
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $mime->header($h);
		defined($v) && length($v) or next;
		$v = PublicInbox::Hval->new_oneline($v);
		$rv .= "$h: " . $v->as_html . "\n";

		if ($h eq 'From') {
			my @from = Email::Address->parse($v->raw);
			$v = $from[0]->name;
			unless (defined($v) && length($v)) {
				$v = '<' . $from[0]->address . '>';
			}
			$title[1] = ascii_html($v);
		} elsif ($h eq 'Subject') {
			$title[0] = $v->as_html;
		}
	}

	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header_raw('Message-ID');
	if (defined $mid) {
		$mid = PublicInbox::Hval->new_msgid($mid);
		$rv .= 'Message-ID: &lt;' . $mid->as_html . '&gt; ';
		my $href = $mid->as_href;
		$href = "../m/$href" unless $full_pfx;
		$rv .= "(<a href=\"$href.txt\">original</a>)\n";
	}

	my $irp = $header_obj->header_raw('In-Reply-To');
	if (defined $irp) {
		my $v = PublicInbox::Hval->new_msgid(my $tmp = $irp);
		my $html = $v->as_html;
		my $href = $v->as_href;
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a href=\"$href.html\">$html</a>&gt;\n";
	}

	my $refs = $header_obj->header_raw('References');
	if ($refs) {
		$refs =~ s/\s*\Q$irp\E\s*// if (defined $irp);
		my @refs = ($refs =~ /<([^>]+)>/g);
		if (@refs) {
			$rv .= 'References: '. linkify_refs(@refs) . "\n";
		}
	}

	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) .
	 '</title></head><body><pre style="white-space:pre-wrap">' .  $rv);
}

sub html_footer {
	my ($mime) = @_;
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
	Email::Address->purge_cache;

	my $subj = $mime->header('Subject') || '';
	$subj = "Re: $subj" unless $subj =~ /\bRe:/;
	my $irp = uri_escape_utf8(
			$mime->header_obj->header_raw('Message-ID') || '');
	delete $cc{$to};
	$to = uri_escape_utf8($to);
	$subj = uri_escape_utf8($subj);

	my $cc = uri_escape_utf8(join(',', values %cc));
	my $href = "mailto:$to?In-Reply-To=$irp&Cc=${cc}&Subject=$subj";

	'<a href="' . ascii_html($href) . '">reply</a>';
}

sub linkify_refs {
	join(' ', map {
		my $v = PublicInbox::Hval->new_msgid($_);
		my $html = $v->as_html;
		my $href = $v->as_href;
		"&lt;<a href=\"$href.html\">$html</a>&gt;";
	} @_);
}

1;
