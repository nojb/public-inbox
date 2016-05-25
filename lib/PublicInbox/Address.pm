# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Address;
use strict;
use warnings;

# very loose regexes, here.  We don't need RFC-compliance,
# just enough to make thing sanely displayable and pass to git

sub emails { ($_[0] =~ /([^<\s]+\@[^>\s]+)/g) }

sub from_name {
	my ($val) = @_;
	my $name = $val;
	$name =~ s/\s*\S+\@\S+\s*\z//;
	if ($name !~ /\S/ || $name =~ /[<>]/) { # git does not like [<>]
		($name) = emails($val);
		$name =~ s/\@.*//;
	}
	$name =~ tr/\r\n\t/ /;
	$name =~ s/\A\s*//;
	$name;
}

1;
