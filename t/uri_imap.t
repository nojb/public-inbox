#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
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
is("$uri", $uri->as_string, '"" overload works');
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
is($uri->uidvalidity, undef, 'no UIDVALIDITY');

$uri = PublicInbox::URIimap->new('imap://0/%');
is($uri->mailbox, '%', "RFC 2192 '%' supported");
$uri = PublicInbox::URIimap->new('imap://0/%25');
$uri = PublicInbox::URIimap->new('imap://0/*');
is($uri->mailbox, '*', "RFC 2192 '*' supported");

$uri = PublicInbox::URIimap->new('imap://0/mmm;UIDVALIDITY=1');
is($uri->mailbox, 'mmm', 'mailbox works with UIDVALIDITY');
is($uri->uidvalidity, 1, 'single-digit UIDVALIDITY');
$uri = PublicInbox::URIimap->new('imap://0/mmm;UIDVALIDITY=21');
is($uri->uidvalidity, 21, 'multi-digit UIDVALIDITY');
$uri = PublicInbox::URIimap->new('imap://0/mmm;UIDVALIDITY=bogus');
is($uri->uidvalidity, undef, 'bogus UIDVALIDITY');
is($uri->uidvalidity(2), 2, 'iuid set');
is($$uri, 'imap://0/mmm;UIDVALIDITY=2', 'bogus uidvalidity replaced');
is($uri->uidvalidity(13), 13, 'iuid set');
is($$uri, 'imap://0/mmm;UIDVALIDITY=13', 'valid uidvalidity replaced');

$uri = PublicInbox::URIimap->new('imap://0/mmm');
is($uri->uidvalidity(2), 2, 'iuid set');
is($$uri, 'imap://0/mmm;UIDVALIDITY=2', 'uidvalidity appended');
is($uri->iuid, undef, 'no iuid');

is(PublicInbox::URIimap->new('imap://0/x;uidvalidity=1')->canonical->as_string,
	'imap://0/x;UIDVALIDITY=1', 'capitalized UIDVALIDITY');

$uri = PublicInbox::URIimap->new('imap://0/mmm/;uid=8');
is($uri->canonical->as_string, 'imap://0/mmm/;UID=8', 'canonicalized UID');
is($uri->mailbox, 'mmm', 'mailbox works with iuid');
is($uri->iuid, 8, 'iuid extracted');
is($uri->iuid(9), 9, 'iuid set');
is($$uri, 'imap://0/mmm/;UID=9', 'correct iuid when stringified');
is($uri->uidvalidity(1), 1, 'set uidvalidity with iuid');
is($$uri, 'imap://0/mmm;UIDVALIDITY=1/;UID=9',
	'uidvalidity added with iuid');
is($uri->uidvalidity(4), 4, 'set uidvalidity with iuid');
is($$uri, 'imap://0/mmm;UIDVALIDITY=4/;UID=9',
	'uidvalidity replaced with iuid');
is($uri->iuid(3), 3, 'iuid set with uidvalidity');
is($$uri, 'imap://0/mmm;UIDVALIDITY=4/;UID=3', 'iuid replaced properly');

my $lc = lc($$uri);
is(PublicInbox::URIimap->new($lc)->canonical->as_string, "$$uri",
	'canonical uppercased both params');

done_testing;
