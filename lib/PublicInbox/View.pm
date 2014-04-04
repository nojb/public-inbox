# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::View;
use strict;
use warnings;
use CGI qw/escapeHTML escape/;
use Encode qw/decode encode/;
use Encode::MIME::Header;

# only one public function:
sub as_html {
	my ($class, $mime) = @_;

	headers_to_html_header($mime) .
		multipart_text_as_html($mime) .
		"</pre>\n";
}

# only private functions below.

sub multipart_text_as_html {
	my ($mime) = @_;
	my $rv = "";
	my $part_nr = 0;

	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses

		my $part_type = $part->content_type;
		if ($part_type =~ m!\btext/[a-z0-9\+\._-]+\b!i) {
			my $fn = $part->filename;

			if ($part_nr > 0) {
				defined($fn) or $fn = "part #$part_nr";
				$rv .= add_filename_line($fn);
			}

			# n.b. $part->body should already be decoded if text
			$rv .= escapeHTML($part->body);
			$rv .= "\n" unless $rv =~ /\n\z/s;
		} else {
			$rv .= "-- part #$part_nr ";
			$rv .= escapeHTML($part_type);
			$rv .= " skipped\n";
		}
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
	"$pad " . escapeHTML($fn) . " $pad\n";
}

sub trim_message_id {
	my ($mid) = @_;
	$mid =~ tr/<>//d;
	my $html = escapeHTML($mid);
	my $href = escapeHTML(escape($mid));

	($html, $href);
}

sub headers_to_html_header {
	my ($simple) = @_;

	my $rv = "";
	my @title;
	foreach my $h (qw(From To Cc Subject Date)) {
		my $v = $simple->header($h);
		defined $v or next;
		$v = decode("MIME-Header", $v);
		$v = encode("utf8", $v);
		$v = escapeHTML($v);
		$v =~ tr/\n/ /;
		$rv .= "$h: $v\n";

		if ($h eq "From" || $h eq "Subject") {
			push @title, $v;
		}
	}

	my $mid = $simple->header('Message-ID');
	if (defined $mid) {
		my ($html, $href) = trim_message_id($mid);
		$rv .= "Message-ID: <a href=$href.html>$html</a> ";
		$rv .= "(<a href=$href.txt>raw message</a>)\n";
	}

	my $irp = $simple->header('In-Reply-To');
	if (defined $irp) {
		my ($html, $href) = trim_message_id($irp);
		$rv .= "In-Reply-To: <a href=$href.html>$html</a>\n";
	}
	$rv .= "\n";

	return ("<html><head><title>".
		join(' - ', @title) .
		'</title></head><body><pre style="white-space:pre-wrap">' .
		$rv);
}

1;
