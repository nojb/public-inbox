# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
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
use warnings;
use Digest::SHA qw/sha1_hex/;

my $SALT = rand;
my $LINK_RE = qr{(\()?\b((?:ftps?|https?|nntps?|gopher)://
		 [\@:\w\.-]+(?:/
		 (?:[a-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@/%]*)
		 (?:\?[a-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@/%]+)?
		 (?:\#[a-z0-9\-\._~!\$\&\';\(\)\*\+,;=:@/%\?]+)?
		 )?
		)}xi;

sub new { bless {}, $_[0] }

sub linkify_1 {
	$_[1] =~ s^$LINK_RE^
		my $beg = $1 || '';
		my $url = $2;
		my $end = '';

		# it's fairly common to end URLs in messages with
		# '.', ',' or ';' to denote the end of a statement;
		# assume the intent was to end the statement/sentence
		# in English
		# Markdown compatibility:
		if ($beg eq '(') {
			if ($url =~ s/(\)[\.,;]?)\z//) {
				$end = $1;
			}
		} elsif ($url =~ s/([\.,;])\z//) {
			$end = $1;
		} elsif ($url !~ /\(/ && $url =~ s/\)\z//) {
			$end = ')';
		}

		# salt this, as this could be exploited to show
		# links in the HTML which don't show up in the raw mail.
		my $key = sha1_hex($url . $SALT);

		# only escape ampersands, others do not match LINK_RE
		$url =~ s/&/&#38;/g;
		$_[0]->{$key} = $url;
		$beg . 'PI-LINK-'. $key . $end;
	^ge;
	$_[1];
}

sub linkify_2 {
	# Added "PI-LINK-" prefix to avoid false-positives on git commits
	$_[1] =~ s!\bPI-LINK-([a-f0-9]{40})\b!
		my $key = $1;
		my $url = $_[0]->{$key};
		if (defined $url) {
			"<a\nhref=\"$url\">$url</a>";
		} else {
			# false positive or somebody tried to mess with us
			$key;
		}
	!ge;
	$_[1];
}

1;
