# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Config;
# see t/nntpd*.t for tests against a live NNTP server

use_ok 'PublicInbox::Watch';
my $nntp_url = \&PublicInbox::Watch::nntp_url;
is('news://example.com/inbox.foo',
	$nntp_url->('NEWS://examplE.com/inbox.foo'), 'lowercased');
is('nntps://example.com/inbox.foo',
	$nntp_url->('nntps://example.com/inbox.foo'), 'nntps:// accepted');
is('nntps://example.com/inbox.foo',
	$nntp_url->('SNEWS://example.com/inbox.foo'), 'snews => nntps');

done_testing;
