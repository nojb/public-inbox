# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Address';

sub test_pkg {
	my ($pkg) = @_;
	my $emails = \&{"${pkg}::emails"};
	my $names = \&{"${pkg}::names"};

	is_deeply([qw(e@example.com e@example.org)],
		[$emails->('User <e@example.com>, e@example.org')],
		'address extraction works as expected');

	is_deeply(['user@example.com'],
		[$emails->('<user@example.com (Comment)>')],
		'comment after domain accepted before >');

	my @names = $names->(
		'User <e@e>, e@e, "John A. Doe" <j@d>, <x@x>, <y@x> (xyz), '.
		'U Ser <u@x> (do not use)');
	is_deeply(\@names, ['User', 'e', 'John A. Doe', 'x', 'xyz', 'U Ser'],
		'name extraction works as expected');

	@names = $names->('"user@example.com" <user@example.com>');
	is_deeply(['user'], \@names,
		'address-as-name extraction works as expected');

	{
		my $backwards = 'u@example.com (John Q. Public)';
		@names = $names->($backwards);
		is_deeply(\@names, ['John Q. Public'], 'backwards name OK');
		my @emails = $emails->($backwards);
		is_deeply(\@emails, ['u@example.com'], 'backwards emails OK');
	}

	@names = $names->('"Quote Unneeded" <user@example.com>');
	is_deeply(['Quote Unneeded'], \@names, 'extra quotes dropped');

	my @emails = $emails->('Local User <user>');
	is_deeply([], \@emails , 'no address for local address');
	@names = $emails->('Local User <user>');
	is_deeply([], \@names, 'no address, no name');
}

test_pkg('PublicInbox::Address');

SKIP: {
	if ($INC{'PublicInbox/AddressPP.pm'}) {
		skip 'Email::Address::XS missing', 8;
	}
	use_ok 'PublicInbox::AddressPP';
	test_pkg('PublicInbox::AddressPP');
}

done_testing;
