# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox;
use strict;
use warnings;
use Email::Address;

# drop plus addressing for matching
sub __drop_plus {
	my ($str_addr) = @_;
	$str_addr =~ s/\+.*\@/\@/;
	$str_addr;
}

# do not allow Bcc, only Cc and To if ORIGINAL_RECIPIENT (postfix) env is set
sub recipient_specified {
	my ($klass, $filter) = @_;
	my $or = $ENV{ORIGINAL_RECIPIENT};
	defined($or) or return 1; # for imports
	my @or = Email::Address->parse($or);
	my $oaddr = __drop_plus($or[0]->address);
	$oaddr = qr/\b\Q$oaddr\E\b/i;
	my @to = Email::Address->parse($filter->to);
	my @cc = Email::Address->parse($filter->cc);
	foreach my $addr (@to, @cc) {
		if (__drop_plus($addr->address) =~ $oaddr) {
			return 1;
		}
	}
	return 0;
}

1;
