# Copyright (C) 2013-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
require_mods('Plack::Util');
use_ok 'PublicInbox::View';

# this only tests View.pm internals which are subject to change,
# see t/plack.t for tests against the PSGI interface.

my $cols = PublicInbox::View::COLS();
my @addr;
until (length(join(', ', @addr)) > ($cols * 2)) {
	push @addr, '"l, f" <a@a>';
	my $n = int(rand(20)) + 1;
	push @addr, ('x'x$n).'@x';
}
my $orig = join(', ', @addr);
my $res = PublicInbox::View::fold_addresses($orig.'');
isnt($res, $orig, 'folded result');
unlike($res, qr/l,\n\tf/s, '"last, first" no broken');
my @nospc = ($res, $orig);
s/\s+//g for @nospc;
is($nospc[0], $nospc[1], 'no addresses lost in translation');
my $tws = PublicInbox::View::fold_addresses($orig.' ');
# (Email::Simple drops leading whitespace, but not trailing)
$tws =~ s/ \z//;
is($tws, $res, 'not thrown off by trailing whitespace');

done_testing();
