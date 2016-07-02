# Copyright (C) 2014-2016 all contributors <meta@public-inbox.org>
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
my $LINK_RE = qr{\b((?:ftps?|https?|nntps?|gopher)://
		 [\@:\w\.-]+/
		 ?[!,:~\$\@\w\+\&\?\.\%\;/#=-]*)}x;

sub new { bless {}, shift }

sub linkify_1 {
	my ($self, $s) = @_;
	$s =~ s!$LINK_RE!
		my $url = $1;
		my $end = '';

		# it's fairly common to end URLs in messages with
		# '.', ',' or ';' to denote the end of a statement;
		# assume the intent was to end the statement/sentence
		# in English
		if ($url =~ s/([\.,;])\z//) {
			$end = $1;
		}

		# salt this, as this could be exploited to show
		# links in the HTML which don't show up in the raw mail.
		my $key = sha1_hex($url . $SALT);

		# only escape ampersands, others do not match LINK_RE
		$url =~ s/&/&#38;/g;
		$self->{$key} = $url;
		'PI-LINK-'. $key . $end;
	!ge;
	$s;
}

sub linkify_2 {
	my ($self, $s) = @_;

	# Added "PI-LINK-" prefix to avoid false-positives on git commits
	$s =~ s!\bPI-LINK-([a-f0-9]{40})\b!
		my $key = $1;
		my $url = $self->{$key};
		if (defined $url) {
			"<a\nhref=\"$url\">$url</a>";
		} else {
			# false positive or somebody tried to mess with us
			$key;
		}
	!ge;
	$s;
}

1;
