# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Address;
use strict;
use warnings;

sub xs_emails {
	grep { defined } map { $_->address() } parse_email_addresses($_[0])
}

sub xs_names {
	grep { defined } map {
		my $n = $_->name;
		my $addr = $_->address;
		$n = $_->user if defined($addr) && $n eq $addr;
		$n;
	} parse_email_addresses($_[0]);
}

eval {
	require Email::Address::XS;
	Email::Address::XS->import(qw(parse_email_addresses));
	*emails = \&xs_emails;
	*names = \&xs_names;
};

if ($@) {
	require PublicInbox::AddressPP;
	*emails = \&PublicInbox::AddressPP::emails;
	*names = \&PublicInbox::AddressPP::names;
}

1;
