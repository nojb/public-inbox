# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Address';

is_deeply([qw(e@example.com e@example.org)],
	[PublicInbox::Address::emails('User <e@example.com>, e@example.org')],
	'address extraction works as expected');

is_deeply(['user@example.com'],
	[PublicInbox::Address::emails('<user@example.com (Comment)>')],
	'comment after domain accepted before >');

my @names = PublicInbox::Address::names(
	'User <e@e>, e@e, "John A. Doe" <j@d>, <x@x>, <y@x> (xyz), '.
	'U Ser <u@x> (do not use)');
is_deeply(\@names, ['User', 'e', 'John A. Doe', 'x', 'xyz', 'U Ser'],
	'name extraction works as expected');

@names = PublicInbox::Address::names('"user@example.com" <user@example.com>');
is_deeply(['user'], \@names, 'address-as-name extraction works as expected');


{
	my $backwards = 'u@example.com (John Q. Public)';
	@names = PublicInbox::Address::names($backwards);
	is_deeply(\@names, ['John Q. Public'], 'backwards name OK');
	my @emails = PublicInbox::Address::emails($backwards);
	is_deeply(\@emails, ['u@example.com'], 'backwards emails OK');
}


@names = PublicInbox::Address::names('"Quote Unneeded" <user@example.com>');
is_deeply(['Quote Unneeded'], \@names, 'extra quotes dropped');

done_testing;
