# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Address;
use strict;
use warnings;

# very loose regexes, here.  We don't need RFC-compliance,
# just enough to make thing sanely displayable and pass to git

sub emails {
	($_[0] =~ /([\w\.\+=\?"\(\)\-!#\$%&'\*\/\^\`\|\{\}~]+\@[\w\.\-\(\)]+)
		(?:\s[^>]*)?>?\s*(?:\(.*?\))?(?:,\s*|\z)/gx)
}

sub names {
	map {
		tr/\r\n\t/ /;
		s/\s*<([^<]+)\z//;
		my $e = $1;
		s/\A['"\s]*//;
		s/['"\s]*\z//;
		$e = $_ =~ /\S/ ? $_ : $e;
		$e =~ s/\@\S+\z//;
		$e;
	} split(/\@+[\w\.\-]+>?\s*(?:\(.*?\))?(?:,\s*|\z)/, $_[0]);
}

1;
