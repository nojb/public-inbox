# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::View;
use strict;
use warnings;
use URI::Escape qw/uri_escape/;
use CGI qw/escapeHTML/;
use Encode qw/find_encoding/;
use Encode::MIME::Header;
use Email::MIME::ContentType qw/parse_content_type/;
use constant MAX_INLINE_QUOTED => 5;

my $enc_utf8 = find_encoding('utf8');
my $enc_ascii = find_encoding('us-ascii');
my $enc_mime = find_encoding('MIME-Header');

# public functions:
sub as_html {
	my ($class, $mime, $full_pfx) = @_;

	headers_to_html_header($mime) .
		multipart_text_as_html($mime, $full_pfx) .
		'</pre></body></html>';
}

sub as_feed_entry {
	my ($class, $mime, $full_pfx) = @_;

	"<pre>" . multipart_text_as_html($mime, $full_pfx) . "</pre>";
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
			$cur =~ s/&gt; ?//g;

			my @sum = split(/\s+/, $cur);
			$cur = '';
			do {
				$cur .= shift(@sum) . ' ';
			} while (@sum && length($cur) < 64);
			$cur=~ s/ \z/ .../;
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

sub trim_message_id {
	my ($mid) = @_;
	$mid = $enc_mime->decode($mid);
	$mid =~ s/\A\s*<//;
	$mid =~ s/>\s*\z//;
	my $html = ascii_html($mid);
	my $href = ascii_html(uri_escape($mid));

	($html, $href);
}

sub ascii_html {
	$enc_ascii->encode(escapeHTML($_[0]), Encode::HTMLCREF);
}

sub headers_to_html_header {
	my ($simple) = @_;

	my $rv = "";
	my @title;
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $simple->header($h);
		defined $v or next;
		$v =~ tr/\n/ /s;
		$v =~ tr/\r//d;
		$v = ascii_html($enc_mime->decode($v));
		$rv .= "$h: $v\n";

		if ($h eq "From" || $h eq "Subject") {
			push @title, $v;
		}
	}

	my $mid = $simple->header('Message-ID');
	if (defined $mid) {
		my ($html, $href) = trim_message_id($mid);
		$rv .= "Message-ID: &lt;<a href=\"$href.html\">$html</a>&gt; ";
		$rv .= "(<a href=\"$href.txt\">original</a>)\n";
	}

	my $irp = $simple->header('In-Reply-To');
	if (defined $irp) {
		my ($html, $href) = trim_message_id($irp);
		$rv .= "In-Reply-To: &lt;";
		$rv .= "<a href=\"$href.html\">$html</a>&gt;\n";
	}
	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) .
	 '</title></head><body><pre style="white-space:pre-wrap">' .  $rv);
}

1;
