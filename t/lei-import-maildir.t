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
	lei_ok(qw(import), "$md/", \'import Maildir');
	my $imp_err = $lei_err;

	my %i;
	lei_ok('inspect', $md); $i{no_type} = $lei_out;
	lei_ok('inspect', "$md/"); $i{no_type_tslash} = $lei_out;
	lei_ok('inspect', "maildir:$md"), $i{with_type} = $lei_out;
	lei_ok('inspect', "maildir:$md/"), $i{with_type_tslash} = $lei_out;
	lei_ok('inspect', "MAILDIR:$md"), $i{ALLCAPS} = $lei_out;
	lei_ok(['inspect', $md], undef, { -C => $ENV{HOME}, %$lei_opt });
	$i{rel_no_type} = $lei_out;
	lei_ok(['inspect', "maildir:$md"], undef,
		{ -C => $ENV{HOME}, %$lei_opt });
	$i{rel_with_type} = $lei_out;
	my %v = map { $_ => 1 } values %i;
	is(scalar(keys %v), 1, 'inspect handles relative and absolute paths');
	my $inspect = json_utf8->decode([ keys %v ]->[0]);
	is_deeply($inspect, {"maildir:$md" => { 'name.count' => 1 }},
		'inspect maildir: path had expected output') or xbail($inspect);

	lei_ok(qw(q s:boolean));
	my $res = json_utf8->decode($lei_out);
	like($res->[0]->{'s'}, qr/use boolean/, 'got expected result')
			or diag explain($imp_err, $res);
	is_deeply($res->[0]->{kw}, ['seen'], 'keyword set');
	is($res->[1], undef, 'only got one result');

	lei_ok('inspect', "blob:$res->[0]->{blob}");
	$inspect = json_utf8->decode($lei_out);
	is(ref(delete $inspect->{"lei/store"}), 'ARRAY', 'lei/store IDs');
	is_deeply($inspect, { 'mail-sync' => { "maildir:$md" => [ 'x:2,S' ] } },
		'maildir sync info as expected');

	lei_ok qw(ls-mail-sync);
	is($lei_out, "maildir:$md\n", 'ls-mail-sync as expected');

	lei_ok(qw(import), $md, \'import Maildir again');
	$imp_err = $lei_err;
	lei_ok(qw(q -d none s:boolean), \'lei q w/o dedupe');
	my $r2 = json_utf8->decode($lei_out);
	is_deeply($r2, $res, 'idempotent import')
			or diag explain($imp_err, $res);
	rename("$md/cur/x:2,S", "$md/cur/x:2,RS") or BAIL_OUT "rename: $!";
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

	lei_ok qw(rm t/data/0001.patch);
	lei_ok(qw(q s:boolean));
	is($lei_out, "[null]\n", 'removed message gone from results');
	my $g0 = "$ENV{HOME}/.local/share/lei/store/local/0.git";
	my $x = xqx(['git', "--git-dir=$g0", qw(cat-file blob HEAD:d)]);
	is($?, 0, "git cat-file shows file is `d'");
});
done_testing;
