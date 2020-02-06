# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::AddressPP;
use strict;

# very loose regexes, here.  We don't need RFC-compliance,
# just enough to make thing sanely displayable and pass to git
# We favor Email::Address::XS for conformance if available

sub emails {
	($_[0] =~ /([\w\.\+=\?"\(\)\-!#\$%&'\*\/\^\`\|\{\}~]+\@[\w\.\-\(\)]+)
		(?:\s[^>]*)?>?\s*(?:\(.*?\))?(?:,\s*|\z)/gx)
}

sub names {
	my @p = split(/<?([^@<>]+)\@[\w\.\-]+>?\s*(\(.*?\))?(?:,\s*|\z)/,
			$_[0]);
	my @ret;
	for (my $i = 0; $i <= $#p;) {
		my $phrase = $p[$i++];
		$phrase =~ tr/\r\n\t / /s;
		$phrase =~ s/\A['"\s]*//;
		$phrase =~ s/['"\s]*\z//;
		my $user = $p[$i++] // '';
		my $comment = $p[$i++] // '';
		if ($phrase =~ /\S/) {
			$phrase =~ s/\@\S+\z//;
			push @ret, $phrase;
		} elsif ($comment =~ /\A\((.*?)\)\z/) {
			push @ret, $1;
		} else {
			push @ret, $user;
		}
	}
	@ret;
}

1;
