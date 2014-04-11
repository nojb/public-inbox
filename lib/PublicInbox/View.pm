# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::View;
use strict;
use warnings;
use URI::Escape qw/uri_escape/;
use CGI qw/escapeHTML/;
use Encode qw/decode encode/;
use Encode::MIME::Header;

# public functions:
sub as_html {
	my ($class, $mime, $full_pfx) = @_;

	headers_to_html_header($mime) .
		multipart_text_as_html($mime, $full_pfx) .
		'</pre>';
}

sub as_feed_entry {
	my ($class, $mime, $full_pfx) = @_;

	"<pre>" . multipart_text_as_html($mime, $full_pfx) . "</pre>";
}


# only private functions below.

sub multipart_text_as_html {
	my ($mime, $full_pfx) = @_;
	my $rv = "";
	my $part_nr = 0;

	# scan through all parts, looking for displayable text
	$mime->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses

		my $fn = $part->filename;

		if ($part_nr > 0) {
			defined($fn) or $fn = "part #" . ($part_nr + 1);
			$rv .= add_filename_line($fn);
		}

		if (defined $full_pfx) {
			$rv .= add_text_body_short($part, $part_nr,
						$full_pfx);
		} else {
			$rv .= add_text_body_full($part, $part_nr);
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
	"$pad " . escapeHTML($fn) . " $pad\n";
}

sub add_text_body_short {
	my ($part, $part_nr, $full_pfx) = @_;
	my $n = 0;
	my $s = escapeHTML($part->body);
	$s =~ s!^((?:(?:&gt;[^\n]+)\n)+)!
		my $cur = $1;
		my @lines = split(/\n/, $cur);
		if (@lines > 1) {
			# show a short snippet of quoted text
			$cur = join(' ', @lines);
			$cur =~ s/&gt; ?//g;

			my @sum = split(/\s+/, $cur);
			$cur = '';
			do {
				$cur .= shift(@sum) . ' ';
			} while (@sum && length($cur) < 68);
			$cur=~ s/ \z/ .../;
			"&gt; &lt;<a href=${full_pfx}#q${part_nr}_" . $n++ .
				">$cur<\/a>&gt;";
		} else {
			$cur;
		}
	!emg;
	$s;
}

sub add_text_body_full {
	my ($part, $part_nr) = @_;
	my $n = 0;
	my $s = escapeHTML($part->body);
	$s =~ s!^((?:(?:&gt;[^\n]+)\n)+)!
		my $cur = $1;
		my @lines = split(/\n/, $cur);
		if (@lines > 1) {
			"<a name=q${part_nr}_" . $n++ . ">$cur</a>";
		} else {
			$cur;
		}
	!emg;
	$s;
}

sub trim_message_id {
	my ($mid) = @_;
	$mid =~ s/\A<//;
	$mid =~ s/>\z//;
	my $html = escapeHTML($mid);
	my $href = escapeHTML(uri_escape($mid));

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
		$rv .= "(<a href=$href.txt>original</a>)\n";
	}

	my $irp = $simple->header('In-Reply-To');
	if (defined $irp) {
		my ($html, $href) = trim_message_id($irp);
		$rv .= "In-Reply-To: <a href=$href.html>$html</a>\n";
	}
	$rv .= "\n";

	("<html><head><title>".  join(' - ', @title) .
	 '</title></head><body><pre style="white-space:pre-wrap">' .  $rv);
}

1;
