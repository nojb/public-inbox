# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Address;
use strict;
use warnings;

# very loose regexes, here.  We don't need RFC-compliance,
# just enough to make thing sanely displayable and pass to git

sub emails { ($_[0] =~ /([\w\.\+=\-]+\@[\w\.\-]+)>?\s*(?:,\s*|\z)/g) }

sub names {
	map {
		tr/\r\n\t/ /;
		s/\s*<([^<]+)\z//;
		my $e = $1;
		s/\A['"\s]*//;
		s/['"\s]*\z//;
		$_ =~ /\S/ ? $_ : $e;
	} split(/\@+[\w\.\-]+>?\s*(?:,\s*|\z)/, $_[0]);
}

sub from_name {
	my ($val) = @_;
	my $name = $val;
	$name =~ s/\s*\S+\@\S+\s*\z//;
	if ($name !~ /\S/ || $name =~ /[<>]/) { # git does not like [<>]
		($name) = emails($val);
		$name =~ s/\@.*//;
	}
	$name =~ tr/\r\n\t/ /;
	$name =~ s/\A['"\s]*//;
	$name =~ s/['"\s]*\z//;
	$name;
}

1;
