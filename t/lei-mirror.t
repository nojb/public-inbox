#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Inbox;
require_mods(qw(-httpd lei));
my $sock = tcp_server();
my ($tmpdir, $for_destroy) = tmpdir();
my $http = 'http://'.tcp_host_port($sock);
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $cmd = [ qw(-httpd -W0 ./t/lei-mirror.psgi),
	"--stdout=$tmpdir/out", "--stderr=$tmpdir/err" ];
my $td = start_script($cmd, { PI_CONFIG => $cfg_path }, { 3 => $sock });
test_lei({ tmpdir => $tmpdir }, sub {
	my $home = $ENV{HOME};
	my $t1 = "$home/t1-mirror";
	lei_ok('add-external', $t1, '--mirror', "$http/t1/", \'--mirror v1');
	ok(-f "$t1/public-inbox/msgmap.sqlite3", 't1-mirror indexed');
	is(PublicInbox::Inbox::try_cat("$t1/description"),
		"mirror of $http/t1/\n", 'description set');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t1\E!, 't1 added to ls-externals');

	my $t2 = "$home/t2-mirror";
	lei_ok('add-external', $t2, '--mirror', "$http/t2/", \'--mirror v2');
	ok(-f "$t2/msgmap.sqlite3", 't2-mirror indexed');
	ok(-f "$t2/description", 't2 description');
	is(PublicInbox::Inbox::try_cat("$t2/description"),
		"mirror of $http/t2/\n", 'description set');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t2\E!, 't2 added to ls-externals');

	ok(!lei('add-external', $t2, '--mirror', "$http/t2/"),
		'--mirror fails if reused') or diag "$lei_err.$lei_out = $?";
	like($lei_err, qr/\Q$t2\E' already exists/, 'destination in error');

	ok(!lei('add-external', "$home/t2\nnewline", '--mirror', "$http/t2/"),
		'--mirror fails on newline');
	like($lei_err, qr/`\\n' not allowed/, 'newline noted in error');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t2\E!, 'still in ls-externals');
	unlike($lei_out, qr!\Qnewline\E!, 'newline entry not added');

	ok(!lei('add-external', "$t2-fail", '-Lmedium'), '--mirror v2');
	like($lei_err, qr/not a directory/, 'non-directory noted');
	ok(!-d "$t2-fail", 'destination not created on failure');
	lei_ok('ls-external');
	unlike($lei_out, qr!\Q$t2-fail\E!, 'not added to ls-external');

	lei_ok('add-external', "$t1-pfx", '--mirror', "$http/pfx/t1/",
			\'--mirror v1 w/ PSGI prefix');
	ok(!-e "$t1-pfx/mirror.done", 'no leftover mirror.done');

	my $d = "$home/404";
	ok(!lei(qw(add-external --mirror), "$http/404", $d), 'mirror 404');
	unlike($lei_err, qr!unlink.*?404/mirror\.done!,
		'no unlink failure message');
	ok(!-d $d, "`404' dir not created");
	lei_ok('ls-external');
	unlike($lei_out, qr!\Q$d\E!s, 'not added to ls-external');

	my %phail = (
		HTTPS => 'https://public-inbox.org/' . 'phail',
		ONION =>
'http://7fh6tueqddpjyxjmgtdiueylzoqt6pt7hec3pukyptlmohoowvhde4yd.onion/' .
'phail,'
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
		like($lei_err, qr/curl.*404/, "curl 404 shown for $k");
	} # SKIP
	} # for
});

SKIP: {
	undef $sock;
	my $d = "$tmpdir/d";
	mkdir $d or xbail "mkdir $d $!";
	my $opt = { -C => $d, 2 => \(my $err) };
	ok(!run_script([qw(-clone -q), "$http/404"], undef, $opt), '404 fails');
	ok(!-d "$d/404", 'destination not created');

	ok(run_script([qw(-clone -q -C), $d, "$http/t2"], undef, $opt),
		'-clone succeeds on v2');
	ok(-d "$d/t2/git/0.git", 'epoch cloned');
	ok(-f "$d/t2/manifest.js.gz", 'manifest saved');
	ok(!-e "$d/t2/mirror.done", 'no leftover mirror.done');
	ok(run_script([qw(-fetch -C), "$d/t2"], undef, $opt),
		'-fetch succeeds w/ manifest.js.gz');
	unlike($err, qr/git fetch/, 'no fetch done w/ manifest');
	unlink("$d/t2/manifest.js.gz") or xbail "unlink $!";
	ok(run_script([qw(-fetch -C), "$d/t2"], undef, $opt),
		'-fetch succeeds w/o manifest.js.gz');
	like($err, qr/git fetch/, 'fetch forced w/o manifest');

	ok(run_script([qw(-clone -q -C), $d, "$http/t1"], undef, $opt),
		'cloning v1 works');
	ok(-d "$d/t1", 'v1 cloned');
	ok(!-e "$d/t1/mirror.done", 'no leftover file');
	ok(-f "$d/t1/manifest.js.gz", 'manifest saved');
	ok(run_script([qw(-fetch -C), "$d/t1"], undef, $opt),
		'fetching v1 works');
	unlike($err, qr/git fetch/, 'no fetch done w/ manifest');
	unlink("$d/t1/manifest.js.gz") or xbail "unlink $!";
	my $before = [ glob("$d/t1/*") ];
	ok(run_script([qw(-fetch -C), "$d/t1"], undef, $opt),
		'fetching v1 works w/o manifest.js.gz');
	unlink("$d/t1/FETCH_HEAD"); # git internal
	like($err, qr/git fetch/, 'no fetch done w/ manifest');
	ok(unlink("$d/t1/manifest.js.gz"), 'manifest created');
	my $after = [ glob("$d/t1/*") ];
	is_deeply($before, $after, 'no new files created');
}

ok($td->kill, 'killed -httpd');
$td->join;

{
	require_ok 'PublicInbox::LeiMirror';
	my $mrr = { src => 'https://example.com/src/', dst => $tmpdir };
	my $exp = "mirror of https://example.com/src/\n";
	my $f = "$tmpdir/description";
	PublicInbox::LeiMirror::set_description($mrr);
	is(PublicInbox::Inbox::try_cat($f), $exp, 'description set on ENOENT');

	my $fh;
	(open($fh, '>', $f) and close($fh)) or xbail $!;
	PublicInbox::LeiMirror::set_description($mrr);
	is(PublicInbox::Inbox::try_cat($f), $exp, 'description set on empty');
	(open($fh, '>', $f) and print $fh "x\n" and close($fh)) or xbail $!;
	is(PublicInbox::Inbox::try_cat($f), "x\n",
		'description preserved if non-default');
}

done_testing;
