#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Cwd qw(abs_path);
test_lei(sub {
	my $md = "$ENV{HOME}/md";
	for ($md, "$md/new", "$md/cur", "$md/tmp") {
		mkdir($_) or BAIL_OUT("mkdir $_: $!");
	}
	symlink(abs_path('t/data/0001.patch'), "$md/cur/x:2,S") or
		BAIL_OUT "symlink $md $!";
	ok($lei->(qw(import), $md), 'import Maildir');
	ok($lei->(qw(q s:boolean)), 'lei q');
	my $res = json_utf8->decode($lei_out);
	like($res->[0]->{'s'}, qr/use boolean/, 'got expected result');
	is_deeply($res->[0]->{kw}, ['seen'], 'keyword set');
	is($res->[1], undef, 'only got one result');

	ok($lei->(qw(import), $md), 'import Maildir again');
	ok($lei->(qw(q -d none s:boolean)), 'lei q w/o dedupe');
	my $r2 = json_utf8->decode($lei_out);
	is_deeply($r2, $res, 'idempotent import');

	rename("$md/cur/x:2,S", "$md/cur/x:2,SR") or BAIL_OUT "rename: $!";
	ok($lei->(qw(import), $md), 'import Maildir after +answered');
	ok($lei->(qw(q -d none s:boolean)), 'lei q after +answered');
	$res = json_utf8->decode($lei_out);
	like($res->[0]->{'s'}, qr/use boolean/, 'got expected result');
	is_deeply($res->[0]->{kw}, ['answered', 'seen'], 'keywords set');
	is($res->[1], undef, 'only got one result');
});
done_testing;
