#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods 'URI';
use_ok 'PublicInbox::URInntps';
my $uri = PublicInbox::URInntps->new('nntp://EXAMPLE.com/inbox.test');
isnt(ref($uri), 'PublicInbox::URInntps', 'URI fallback');
is($uri->scheme, 'nntp', 'NNTP fallback ->scheme');

$uri = PublicInbox::URInntps->new('nntps://EXAMPLE.com/inbox.test');
is($uri->host, 'EXAMPLE.com', 'host matches');
is($uri->canonical->host, 'example.com', 'host canonicalized');
is($uri->canonical->as_string, 'nntps://example.com/inbox.test',
	'URI canonicalized');
is($uri->port, 563, 'nntps port');
is($uri->userinfo, undef, 'no userinfo');
is($uri->scheme, 'nntps', '->scheme works');
is($uri->group, 'inbox.test', '->group works');

$uri = PublicInbox::URInntps->new('nntps://foo@0/');
is("$uri", $uri->as_string, '"" overload works');
is($uri->host, '0', 'numeric host');
is($uri->userinfo, 'foo', 'user extracted');

$uri = PublicInbox::URInntps->new('nntps://ipv6@[::1]');
is($uri->host, '::1', 'IPv6 host');
is($uri->group, '', '->group is empty');

$uri = PublicInbox::URInntps->new('nntps://0:666/INBOX.test');
is($uri->port, 666, 'port read');
is($uri->group, 'INBOX.test', 'group read after port');

is(PublicInbox::URInntps->new('nntps://0:563/')->canonical->as_string,
	'nntps://0/', 'default port stripped');

$uri = PublicInbox::URInntps->new('nntps://NSA:Hunter2@0/inbox');
is($uri->userinfo, 'NSA:Hunter2', 'userinfo accepted w/ pass');

$uri = PublicInbox::URInntps->new('nntps://NSA:Hunter2@0/inbox.test/9-10');
is_deeply([$uri->group], [ 'inbox.test', 9, 10 ], 'ranges work');

done_testing;
