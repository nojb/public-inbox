#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
use PublicInbox::TestCommon;
use URI;
require_mods 'IO::Socket::Socks';
use_ok 'PublicInbox::NetNNTPSocks';
my $url = $ENV{TEST_NNTP_ONION_URL} //
	'nntp://ie5yzdi7fg72h7s4sdcztq5evakq23rdt33mfyfcddc5u3ndnw24ogqd.onion/inbox.comp.mail.public-inbox.meta';
my $uri = URI->new($url);
my $on = PublicInbox::NetNNTPSocks->new_socks(
	Port => $uri->port,
	Host => $uri->host,
	ProxyAddr => '127.0.0.1', # default Tor address + port
	ProxyPort => 9050,
) or xbail('err = '.eval('$IO::Socket::Socks::SOCKS_ERROR'));
my ($nr, $min, $max, $grp) = $on->group($uri->group);
ok($nr > 0 && $min > 0 && $min < $max, 'nr, min, max make sense') or
	diag explain([$nr, $min, $max, $grp]);
is($grp, $uri->group, 'group matches');
done_testing;
