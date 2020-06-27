# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Config;
# see t/imapd*.t for tests against a live IMAP server

use_ok 'PublicInbox::WatchMaildir';
my $cfg = PublicInbox::Config->new(\<<EOF);
publicinbox.i.address=i\@example.com
publicinbox.i.inboxdir=/nonexistent
publicinbox.i.watch=imap://example.com/INBOX.a
publicinboxlearn.watchspam=imap://example.com/INBOX.spam
EOF
my $watch = PublicInbox::WatchMaildir->new($cfg);
is($watch->{imap}->{'imap://example.com/INBOX.a'}->[0]->{name}, 'i',
	'watched an inbox');
is($watch->{imap}->{'imap://example.com/INBOX.spam'}, 'watchspam',
	'watched spam folder');

done_testing;
