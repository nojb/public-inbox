#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(-httpd lei));
my $sock = tcp_server();
my ($tmpdir, $for_destroy) = tmpdir();
my $http = 'http://'.tcp_host_port($sock);
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $cmd = [ qw(-httpd -W0), "--stdout=$tmpdir/out", "--stderr=$tmpdir/err" ];
my $td = start_script($cmd, { PI_CONFIG => $cfg_path }, { 3 => $sock });
test_lei({ tmpdir => $tmpdir }, sub {
	my $home = $ENV{HOME};
	my $t1 = "$home/t1-mirror";
	lei_ok('add-external', $t1, '--mirror', "$http/t1/", \'--mirror v1');
	ok(-f "$t1/public-inbox/msgmap.sqlite3", 't1-mirror indexed');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t1\E!, 't1 added to ls-externals');

	my $t2 = "$home/t2-mirror";
	lei_ok('add-external', $t2, '--mirror', "$http/t2/", \'--mirror v2');
	ok(-f "$t2/msgmap.sqlite3", 't2-mirror indexed');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t2\E!, 't2 added to ls-externals');

	ok(!lei('add-external', $t2, '--mirror', "$http/t2/"),
		'--mirror fails if reused') or diag "$lei_err.$lei_out = $?";

	ok(!lei('add-external', "$home/t2\nnewline", '--mirror', "$http/t2/"),
		'--mirror fails on newline');
	like($lei_err, qr/`\\n' not allowed/, 'newline noted in error');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t2\E!, 'still in ls-externals');
	unlike($lei_out, qr!\Qnewline\E!, 'newline entry not added');

	ok(!lei('add-external', "$t2-fail", '-Lmedium'), '--mirror v2');
	ok(!-d "$t2-fail", 'destination not created on failure');
	lei_ok('ls-external');
	unlike($lei_out, qr!\Q$t2-fail\E!, 'not added to ls-external');

	my %phail = (
		HTTPS => 'https://public-inbox.org/' . 'phail',
		ONION => 'http://ou63pmih66umazou.onion/' . 'phail,'
	);
	for my $t (qw(HTTPS ONION)) {
	SKIP: {
		my $k = "TEST_LEI_EXTERNAL_$t";
		$ENV{$k} or skip "$k unset", 1;
		my $url = $phail{$t};
		my $dir = "phail-$t";
		ok(!lei(qw(add-external -Lmedium --mirror),
			$url, $dir), '--mirror non-existent v2');
		is($? >> 8, 22, 'curl 404');
		ok(!-d $dir, 'directory not created');
		unlike($lei_err, qr/# mirrored/, 'no success message');
	} # SKIP
	} # for
});

ok($td->kill, 'killed -httpd');
$td->join;

done_testing;
