#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
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
is($uri->uidvalidity(2), 2, 'uid set');
is($$uri, 'imap://0/mmm;UIDVALIDITY=2', 'bogus uidvalidity replaced');
is($uri->uidvalidity(13), 13, 'uid set');
is($$uri, 'imap://0/mmm;UIDVALIDITY=13', 'valid uidvalidity replaced');

$uri = PublicInbox::URIimap->new('imap://0/mmm');
is($uri->uidvalidity(2), 2, 'uid set');
is($$uri, 'imap://0/mmm;UIDVALIDITY=2', 'uidvalidity appended');
is($uri->uid, undef, 'no uid');

is(PublicInbox::URIimap->new('imap://0/x;uidvalidity=1')->canonical->as_string,
	'imap://0/x;UIDVALIDITY=1', 'capitalized UIDVALIDITY');

$uri = PublicInbox::URIimap->new('imap://0/mmm/;uid=8');
is($uri->canonical->as_string, 'imap://0/mmm/;UID=8', 'canonicalized UID');
is($uri->mailbox, 'mmm', 'mailbox works with uid');
is($uri->uid, 8, 'uid extracted');
is($uri->uid(9), 9, 'uid set');
is($$uri, 'imap://0/mmm/;UID=9', 'correct uid when stringified');
is($uri->uidvalidity(1), 1, 'set uidvalidity with uid');
is($$uri, 'imap://0/mmm;UIDVALIDITY=1/;UID=9',
	'uidvalidity added with uid');
is($uri->uidvalidity(4), 4, 'set uidvalidity with uid');
is($$uri, 'imap://0/mmm;UIDVALIDITY=4/;UID=9',
	'uidvalidity replaced with uid');
is($uri->uid(3), 3, 'uid set with uidvalidity');
is($$uri, 'imap://0/mmm;UIDVALIDITY=4/;UID=3', 'uid replaced properly');

my $lc = lc($$uri);
is(PublicInbox::URIimap->new($lc)->canonical->as_string, "$$uri",
	'canonical uppercased both params');

is($uri->uid(undef), undef, 'uid can be clobbered');
is($$uri, 'imap://0/mmm;UIDVALIDITY=4', 'uid dropped');

$uri->auth('ANONYMOUS');
is($$uri, 'imap://;AUTH=ANONYMOUS@0/mmm;UIDVALIDITY=4', 'AUTH= set');
is($uri->user, undef, 'user is undef w/ AUTH=');
is($uri->password, undef, 'password is undef w/ AUTH=');

$uri->user('foo');
is($$uri, 'imap://foo;AUTH=ANONYMOUS@0/mmm;UIDVALIDITY=4', 'user set w/AUTH');
is($uri->password, undef, 'password is undef w/ AUTH= & user');
$uri->auth(undef);
is($$uri, 'imap://foo@0/mmm;UIDVALIDITY=4', 'user remains set w/o auth');
is($uri->password, undef, 'password is undef w/ user only');

$uri->user('bar');
is($$uri, 'imap://bar@0/mmm;UIDVALIDITY=4', 'user set w/o AUTH');
$uri->auth('NTML');
is($$uri, 'imap://bar;AUTH=NTML@0/mmm;UIDVALIDITY=4', 'auth set w/user');
$uri->auth(undef);
$uri->user(undef);
is($$uri, 'imap://0/mmm;UIDVALIDITY=4', 'auth and user both cleared');
is($uri->user, undef, 'user is undef');
is($uri->auth, undef, 'auth is undef');
is($uri->password, undef, 'password is undef');
$uri = PublicInbox::URIimap->new('imap://[::1]:36281/');
my $cred = bless { username => $uri->user, password => $uri->password };
is($cred->{username}, undef, 'user is undef in array context');
is($cred->{password}, undef, 'password is undef in array context');
$uri = PublicInbox::URIimap->new('imap://u@example.com/slash/separator');
is($uri->mailbox, 'slash/separator', "`/' separator accepted");
is($uri->uidvalidity(6), 6, "UIDVALIDITY set with `/' separator");
is($$uri, 'imap://u@example.com/slash/separator;UIDVALIDITY=6',
	"URI correct after adding UIDVALIDITY w/ `/' separator");

$uri = PublicInbox::URIimap->new('imap://u@example.com/a/b;UIDVALIDITY=3');
is($uri->uidvalidity, 3, "UIDVALIDITY w/ `/' separator");
is($uri->mailbox, 'a/b', "mailbox w/ `/' separator + UIDVALIDITY");
is($uri->uidvalidity(4), 4, "UIDVALIDITY set w/ `/' separator");
is($$uri, 'imap://u@example.com/a/b;UIDVALIDITY=4',
	"URI correct after replacing UIDVALIDITY w/ `/' separator");
is($uri->uid(5), 5, "set /;UID= w/ `/' separator");

$uri = PublicInbox::URIimap->new('imap://u@example.com/a/b/;UID=9');
is($uri->uid, 9, "UID read with `/' separator w/o UIDVALIDITY");
is($uri->uid(8), 8, "UID set with `/' separator w/o UIDVALIDITY");
is($$uri, 'imap://u@example.com/a/b/;UID=8',
	"URI correct after replacing UID w/ `/' separator");

done_testing;
