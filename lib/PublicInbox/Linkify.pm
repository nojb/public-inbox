# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# two-step linkification.
# intended usage is in the following order:
#
#   linkify_1
#   <escape unsafe chars for HTML>
#   linkify_2
#
# Maybe this could be done more efficiently...
package PublicInbox::Linkify;
use strict;
use v5.10.1;
use Digest::SHA qw/sha1_hex/;
use PublicInbox::Hval qw(ascii_html mid_href);
use PublicInbox::MID qw($MID_EXTRACT);

my $SALT = rand;
my $LINK_RE = qr{([\('!])?\b((?:ftps?|https?|nntps?|imaps?|s?news|gopher)://
		 [\@:\w\.-]+(?:/
		 (?:[a-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@/%]*)
		 (?:\?[a-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@/%]+)?
		 (?:\#[a-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@/%\?]+)?
		 )?
		)}xi;

sub new { bless {}, $_[0] }

# try to distinguish paired punctuation chars from the URL itself
# Maybe other languages/formats can be supported here, too...
my %pairs = (
	"(" => qr/(\)[\.,;\+]?)\z/, # Markdown (,), Ruby (+) (, for arrays)
	"'" => qr/('[\.,;\+]?)\z/, # Perl / Ruby
	"!" => qr/(![\.,;\+]?)\z/, # Perl / Ruby
);

sub linkify_1 {
	$_[1] =~ s^$LINK_RE^
		my $beg = $1 || '';
		my $url = $2;
		my $end = '';

		# it's fairly common to end URLs in messages with
		# '.', ',' or ';' to denote the end of a statement;
		# assume the intent was to end the statement/sentence
		# in English
		if (defined(my $re = $pairs{$beg})) {
			if ($url =~ s/$re//) {
				$end = $1;
			}
		} elsif ($url =~ s/(\))?([\.,;])\z//) {
			$end = $2;
			# require ')' to be paired with '('
			if (defined $1) { # ')'
				if (index($url, '(') < 0) {
					$end = ")$end";
				} else {
					$url .= ')';
				}
			}
		} elsif ($url !~ /\(/ && $url =~ s/\)\z//) {
			$end = ')';
		}

		$url = ascii_html($url); # for IDN

		# salt this, as this could be exploited to show
		# links in the HTML which don't show up in the raw mail.
		my $key = sha1_hex($url . $SALT);
		$key =~ tr/0-9/A-J/; # no digits for YAML highlight
		$_[0]->{$key} = $url;
		$beg . 'LINKIFY' . $key . $end;
	^geo;
	$_[1];
}

sub linkify_2 {
	# Added "LINKIFY" prefix to avoid false-positives on git commits
	$_[1] =~ s!\bLINKIFY([a-fA-J]{40})\b!
		my $key = $1;
		my $url = $_[0]->{$key};
		if (defined $url) {
			"<a\nhref=\"$url\">$url</a>";
		} else { # false positive or somebody tried to mess with us
			'LINKIFY'.$key;
		}
	!ge;
	$_[1];
}

# single pass linkification of <Message-ID@example.com> within $str
# with $pfx being the URL prefix
sub linkify_mids {
	my ($self, $pfx, $str, $raw) = @_;
	$$str =~ s!$MID_EXTRACT!
		my $mid = $1;
		my $html = ascii_html($mid);
		my $href = mid_href($mid);

		# salt this, as this could be exploited to show
		# links in the HTML which don't show up in the raw mail.
		my $key = sha1_hex($html . $SALT);
		$key =~ tr/0-9/A-J/;
		my $repl = qq(&lt;<a\nhref="$pfx/$href/">$html</a>&gt;);
		$repl .= qq{ (<a\nhref="$pfx/$href/raw">raw</a>)} if $raw;
		$self->{$key} = $repl;
		'LINKIFY'.$key;
		!ge;
	$$str = ascii_html($$str);
	$$str =~ s!\bLINKIFY([a-fA-J]{40})\b!
		my $key = $1;
		my $repl = $_[0]->{$key};
		if (defined $repl) {
			$repl;
		} else { # false positive or somebody tried to mess with us
			'LINKIFY'.$key;
		}
	!ge;
}

sub to_html { linkify_2($_[0], ascii_html(linkify_1(@_))) }

1;
