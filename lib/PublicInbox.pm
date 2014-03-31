# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox;
use strict;
use warnings;
use Email::Address;
use constant MAX_SIZE => 1024 * 500; # same as spamc default

# drop plus addressing for matching
sub __drop_plus {
	my ($str_addr) = @_;
	$str_addr =~ s/\+.*\@/\@/;
	$str_addr;
}

# do not allow Bcc, only Cc and To if recipient is set
sub precheck {
	my ($klass, $filter, $recipient) = @_;
	my $simple = $filter->simple;
	return 0 unless $simple->header("Message-ID");
	return 0 unless defined($filter->from);
	return 0 if length($simple->as_string) > MAX_SIZE;
	recipient_specified($filter, $recipient);
}

sub recipient_specified {
	my ($filter, $recipient) = @_;
	defined($recipient) or return 1; # for mass imports
	my @recip = Email::Address->parse($recipient);
	my $oaddr = __drop_plus($recip[0]->address);
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
