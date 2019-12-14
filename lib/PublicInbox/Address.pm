# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Address;
use strict;
use warnings;

sub xs_emails { map { $_->address() } parse_email_addresses($_[0]) }

sub xs_names {
	map {
		my $n = $_->name;
		$n = $_->user if $n eq $_->address;
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
