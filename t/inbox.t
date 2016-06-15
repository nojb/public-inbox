# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::Inbox';
my $x = PublicInbox::Inbox->new({url => '//example.com/test/'});
is($x->base_url, 'https://example.com/test/', 'expanded protocol-relative');
$x = PublicInbox::Inbox->new({url => 'http://example.com/test'});
is($x->base_url, 'http://example.com/test/', 'added trailing slash');

$x = PublicInbox::Inbox->new({});
is($x->base_url, undef, 'undef base_url allowed');

done_testing();
