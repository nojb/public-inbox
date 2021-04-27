#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(lei));

test_lei(sub {
	my $in = "\nMessage-id: <qp\@example.com>\n";
	lei_ok([qw(lcat --stdin)], undef, { 0 => \$in, %$lei_opt });
	unlike($lei_out, qr/\S/, 'nothing, yet');
	lei_ok('import', 't/plack-qp.eml');
	lei_ok([qw(lcat --stdin)], undef, { 0 => \$in, %$lei_opt });
	like($lei_out, qr/qp\@example\.com/, 'got a result');
});

done_testing;
