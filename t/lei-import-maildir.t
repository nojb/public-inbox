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
	lei_ok(qw(import), $md, \'import Maildir');
	my $imp_err = $lei_err;
	lei_ok(qw(q s:boolean));
	my $res = json_utf8->decode($lei_out);
	like($res->[0]->{'s'}, qr/use boolean/, 'got expected result')
			or diag explain($imp_err, $res);
	is_deeply($res->[0]->{kw}, ['seen'], 'keyword set');
	is($res->[1], undef, 'only got one result');

	lei_ok(qw(import), $md, \'import Maildir again');
	$imp_err = $lei_err;
	lei_ok(qw(q -d none s:boolean), \'lei q w/o dedupe');
	my $r2 = json_utf8->decode($lei_out);
	is_deeply($r2, $res, 'idempotent import')
			or diag explain($imp_err, $res);
	rename("$md/cur/x:2,S", "$md/cur/x:2,SR") or BAIL_OUT "rename: $!";
	lei_ok('import', "maildir:$md", \'import Maildir after +answered');
	lei_ok(qw(q -d none s:boolean), \'lei q after +answered');
	$res = json_utf8->decode($lei_out);
	like($res->[0]->{'s'}, qr/use boolean/, 'got expected result');
	is_deeply($res->[0]->{kw}, ['answered', 'seen'], 'keywords set');
	is($res->[1], undef, 'only got one result');

	symlink(abs_path('t/utf8.eml'), "$md/cur/u:2,ST") or
		BAIL_OUT "symlink $md $!";
	lei_ok('import', "maildir:$md", \'import Maildir w/ trashed message');
	$imp_err = $lei_err;
	lei_ok(qw(q -d none m:testmessage@example.com));
	$res = json_utf8->decode($lei_out);
	is_deeply($res, [ undef ], 'trashed message not imported')
			or diag explain($imp_err, $res);
});
done_testing;
