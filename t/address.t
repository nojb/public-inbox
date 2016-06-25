# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Address';

is_deeply([qw(e@example.com e@example.org)],
	[PublicInbox::Address::emails('User <e@example.com>, e@example.org')],
	'address extraction works as expected');

is_deeply([PublicInbox::Address::emails('"ex@example.com" <ex@example.com>')],
	[qw(ex@example.com)]);

my @names = PublicInbox::Address::names(
	'User <e@e>, e@e, "John A. Doe" <j@d>, <x@x>');
is_deeply(['User', 'e', 'John A. Doe', 'x'], \@names,
	'name extraction works as expected');


done_testing;
