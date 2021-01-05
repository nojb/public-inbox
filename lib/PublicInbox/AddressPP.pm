# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
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
	# split by address and post-address comment
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

sub pairs { # for JMAP, RFC 8621 section 4.1.2.3
	my ($s) = @_;
	[ map {
		my $addr = $_;
		if ($s =~ s/\A\s*(.*?)\s*<\Q$addr\E>\s*(.*?)\s*(?:,|\z)// ||
		    $s =~ s/\A\s*(.*?)\s*\Q$addr\E\s*(.*?)\s*(?:,|\z)//) {
			my ($phrase, $comment) = ($1, $2);
			$phrase =~ tr/\r\n\t / /s;
			$phrase =~ s/\A['"\s]*//;
			$phrase =~ s/['"\s]*\z//;
			$phrase =~ s/\s*<*\s*\z//;
			$phrase = undef if $phrase !~ /\S/;
			$comment = ($comment =~ /\((.*?)\)/) ? $1 : undef;
			[ $phrase // $comment, $addr ]
		} else {
			();
		}
	} emails($s) ];
}

1;
