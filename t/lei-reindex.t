#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12; use PublicInbox::TestCommon;
require_mods(qw(lei));
my ($tmpdir, $for_destroy) = tmpdir;
test_lei(sub {
	ok(!lei('reindex'), 'reindex fails w/o store');
	like $lei_err, qr/nothing indexed/, "`nothing indexed' noted";
});

done_testing;
