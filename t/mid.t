# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use PublicInbox::MID qw(mid_escape);

is(mid_escape('foo!@(bar)'), 'foo!@(bar)');
is(mid_escape('foo%!@(bar)'), 'foo%25!@(bar)');
is(mid_escape('foo%!@(bar)'), 'foo%25!@(bar)');

done_testing();
1;
