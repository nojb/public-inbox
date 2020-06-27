#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
require_mods 'URI::Split';
use_ok 'PublicInbox::URIimap';

is(PublicInbox::URIimap->new('https://example.com/'), undef,
	'invalid scheme ignored');

my $uri = PublicInbox::URIimap->new('imaps://EXAMPLE.com/');
is($uri->host, 'EXAMPLE.com', 'host ok');
is($uri->canonical->host, 'example.com', 'host canonicalized');
is($uri->canonical->as_string, 'imaps://example.com/', 'URI canonicalized');
is($uri->port, 993, 'imaps port');
is($uri->auth, undef);
is($uri->user, undef);

$uri = PublicInbox::URIimap->new('imaps://foo@0/');
is($uri->host, '0', 'numeric host');
is($uri->user, 'foo', 'user extracted');

$uri = PublicInbox::URIimap->new('imap://0/INBOX.sub#frag')->canonical;
is($uri->as_string, 'imap://0/INBOX.sub', 'no fragment');
is($uri->scheme, 'imap');

$uri = PublicInbox::URIimap->new('imaps://;AUTH=ANONYMOUS@0/');
is($uri->auth, 'ANONYMOUS', 'AUTH=ANONYMOUS accepted');

$uri = PublicInbox::URIimap->new('imaps://bar%40example.com;AUTH=99%25@0/');
is($uri->auth, '99%', 'decoded AUTH');
is($uri->user, 'bar@example.com', 'decoded user');
is($uri->mailbox, undef, 'mailbox is undef');

$uri = PublicInbox::URIimap->new('imaps://ipv6@[::1]');
is($uri->host, '::1', 'IPv6 host');
is($uri->mailbox, undef, 'mailbox is undef');

$uri = PublicInbox::URIimap->new('imaps://0:666/INBOX');
is($uri->port, 666, 'port read');
is($uri->mailbox, 'INBOX');
$uri = PublicInbox::URIimap->new('imaps://0/INBOX.sub');
is($uri->mailbox, 'INBOX.sub');
is($uri->scheme, 'imaps');

is(PublicInbox::URIimap->new('imap://0:143/')->canonical->as_string,
	'imap://0/');
is(PublicInbox::URIimap->new('imaps://0:993/')->canonical->as_string,
	'imaps://0/');

$uri = PublicInbox::URIimap->new('imap://NSA:Hunter2@0/INBOX');
is($uri->user, 'NSA');
is($uri->password, 'Hunter2');

$uri = PublicInbox::URIimap->new('imap://0/%');
is($uri->mailbox, '%', "RFC 2192 '%' supported");
$uri = PublicInbox::URIimap->new('imap://0/%25');
$uri = PublicInbox::URIimap->new('imap://0/*');
is($uri->mailbox, '*', "RFC 2192 '*' supported");

# TODO: support UIDVALIDITY and other params

done_testing;
