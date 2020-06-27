# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Config;
# see t/nntpd*.t for tests against a live NNTP server

use_ok 'PublicInbox::WatchMaildir';
my $nntp_url = \&PublicInbox::WatchMaildir::nntp_url;
is('news://example.com/inbox.foo',
	$nntp_url->('NEWS://examplE.com/inbox.foo'), 'lowercased');
is('snews://example.com/inbox.foo',
	$nntp_url->('nntps://example.com/inbox.foo'), 'nntps:// is snews://');

done_testing;
