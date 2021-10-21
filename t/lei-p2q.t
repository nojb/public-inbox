#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));

test_lei(sub {
	ok(!lei(qw(p2q this-better-cause-format-patch-to-fail)),
		'p2q fails on bogus arg') or diag $lei_err;
	like($lei_err, qr/format-patch.*failed/, 'notes format-patch failure');
	lei_ok(qw(p2q -w dfpost t/data/0001.patch));
	is($lei_out, "dfpost:6e006fd73b1d\n", 'pathname') or diag $lei_err;
	open my $fh, '+<', 't/data/0001.patch' or xbail "open: $!";
	lei_ok([qw(p2q -w dfpost -)], undef, { %$lei_opt, 0 => $fh });
	is($lei_out, "dfpost:6e006fd73b1d\n", '--stdin') or diag $lei_err;

	sysseek($fh, 0, 0) or xbail "lseek: $!";
	lei_ok([qw(p2q -w dfpost)], undef, { %$lei_opt, 0 => $fh });
	is($lei_out, "dfpost:6e006fd73b1d\n", 'implicit --stdin');

	lei_ok(qw(p2q --uri t/data/0001.patch -w), 'dfpost,dfn');
	is($lei_out, "dfpost%3A6e006fd73b1d+".
		"dfn%3Alib%2FPublicInbox%2FSearch.pm\n",
		'--uri -w dfpost,dfn');
	lei_ok(qw(p2q t/data/0001.patch), '--want=dfpost,OR,dfn');
	is($lei_out, "dfpost:6e006fd73b1d OR dfn:lib/PublicInbox/Search.pm\n",
		'--want=OR');
	lei_ok(qw(p2q t/data/0001.patch --want=dfpost9));
	is($lei_out, "dfpost:6e006fd73b1d OR " .
			"dfpost:6e006fd73b1 OR " .
			"dfpost:6e006fd73b OR " .
			"dfpost:6e006fd73\n",
		'3-byte chop');

	lei_ok(qw(p2q t/data/message_embed.eml --want=dfb));
	like($lei_out, qr/\bdfb:\S+/, 'got dfb off /dev/null file');
});
done_testing;
