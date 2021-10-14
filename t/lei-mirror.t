#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Inbox;
require_mods(qw(-httpd lei DBD::SQLite));
require_cmd('curl');
require PublicInbox::Msgmap;
my $sock = tcp_server();
my ($tmpdir, $for_destroy) = tmpdir();
my $http = 'http://'.tcp_host_port($sock);
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $cmd = [ qw(-httpd -W0 ./t/lei-mirror.psgi),
	"--stdout=$tmpdir/out", "--stderr=$tmpdir/err" ];
my $td = start_script($cmd, { PI_CONFIG => $cfg_path }, { 3 => $sock });
my %created;
test_lei({ tmpdir => $tmpdir }, sub {
	my $home = $ENV{HOME};
	my $t1 = "$home/t1-mirror";
	my $mm_orig = "$ro_home/t1/public-inbox/msgmap.sqlite3";
	$created{v1} = PublicInbox::Msgmap->new_file($mm_orig)->created_at;
	lei_ok('add-external', $t1, '--mirror', "$http/t1/", \'--mirror v1');
	my $mm_dup = "$t1/public-inbox/msgmap.sqlite3";
	ok(-f $mm_dup, 't1-mirror indexed');
	is(PublicInbox::Inbox::try_cat("$t1/description"),
		"mirror of $http/t1/\n", 'description set');
	ok(-f "$t1/Makefile", 'convenience Makefile added (v1)');
	ok(-f "$t1/inbox.config.example", 'inbox.config.example downloaded');
	is((stat(_))[9], $created{v1},
		'inbox.config.example mtime is ->created_at');
	is((stat(_))[2] & 0222, 0, 'inbox.config.example not writable');
	my $tb = PublicInbox::Msgmap->new_file($mm_dup)->created_at;
	is($tb, $created{v1}, 'created_at matched in mirror');

	lei_ok('ls-external');
	like($lei_out, qr!\Q$t1\E!, 't1 added to ls-externals');

	my $t2 = "$home/t2-mirror";
	$mm_orig = "$ro_home/t2/msgmap.sqlite3";
	$created{v2} = PublicInbox::Msgmap->new_file($mm_orig)->created_at;
	lei_ok('add-external', $t2, '--mirror', "$http/t2/", \'--mirror v2');
	$mm_dup = "$t2/msgmap.sqlite3";
	ok(-f $mm_dup, 't2-mirror indexed');
	ok(-f "$t2/description", 't2 description');
	ok(-f "$t2/Makefile", 'convenience Makefile added (v2)');
	is(PublicInbox::Inbox::try_cat("$t2/description"),
		"mirror of $http/t2/\n", 'description set');
	$tb = PublicInbox::Msgmap->new_file($mm_dup)->created_at;
	is($tb, $created{v2}, 'created_at matched in v2 mirror');

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

	$d = "$home/bad-epoch";
	ok(!lei(qw(add-external -q --epoch=0.. --mirror), "$http/t1/", $d),
		'v1 fails on --epoch');
	ok(!-d $d, 'destination not created on unacceptable --epoch');
	ok(!lei(qw(add-external -q --epoch=1 --mirror), "$http/t2/", $d),
		'v2 fails on bad epoch range');
	ok(!-d $d, 'destination not created on bad epoch');

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
	ok(-f "$d/t2/git/0.git/config", 'epoch cloned');

	# writeBitmaps is the default for bare repos in git 2.22+,
	# so we may stop setting it ourselves.
	0 and is(xqx(['git', "--git-dir=$d/t2/git/0.git", 'config',
		qw(--bool repack.writeBitmaps)]), "true\n",
		'write bitmaps set (via include.path=all.git/config');

	is(xqx(['git', "--git-dir=$d/t2/git/0.git", 'config',
		qw(include.path)]), "../../all.git/config\n",
		'include.path set');

	ok(-s "$d/t2/all.git/objects/info/alternates",
		'all.git alternates created');
	ok(-f "$d/t2/manifest.js.gz", 'manifest saved');
	ok(!-e "$d/t2/mirror.done", 'no leftover mirror.done');
	ok(!run_script([qw(-fetch --exit-code -C), "$d/t2"], undef, $opt),
		'-fetch succeeds w/ manifest.js.gz');
	is($? >> 8, 127, '--exit-code gave 127');
	unlike($err, qr/git --git-dir=\S+ fetch/, 'no fetch done w/ manifest');
	unlink("$d/t2/manifest.js.gz") or xbail "unlink $!";
	ok(!run_script([qw(-fetch --exit-code -C), "$d/t2"], undef, $opt),
		'-fetch succeeds w/o manifest.js.gz');
	is($? >> 8, 127, '--exit-code gave 127');
	like($err, qr/git --git-dir=\S+ fetch/, 'fetch forced w/o manifest');

	ok(run_script([qw(-clone -q -C), $d, "$http/t1"], undef, $opt),
		'cloning v1 works');
	ok(-d "$d/t1", 'v1 cloned');
	ok(!-e "$d/t1/mirror.done", 'no leftover file');
	ok(-f "$d/t1/manifest.js.gz", 'manifest saved');
	ok(!run_script([qw(-fetch --exit-code -C), "$d/t1"], undef, $opt),
		'fetching v1 works');
	is($? >> 8, 127, '--exit-code gave 127');
	unlike($err, qr/git --git-dir=\S+ fetch/, 'no fetch done w/ manifest');
	unlink("$d/t1/manifest.js.gz") or xbail "unlink $!";
	my $before = [ glob("$d/t1/*") ];
	ok(!run_script([qw(-fetch --exit-code -C), "$d/t1"], undef, $opt),
		'fetching v1 works w/o manifest.js.gz');
	is($? >> 8, 127, '--exit-code gave 127');
	unlink("$d/t1/FETCH_HEAD"); # git internal
	like($err, qr/git --git-dir=\S+ fetch/, 'no fetch done w/ manifest');
	ok(unlink("$d/t1/manifest.js.gz"), 'manifest created');
	my $after = [ glob("$d/t1/*") ];
	is_deeply($before, $after, 'no new files created');

	local $ENV{HOME} = $tmpdir;
	ok(run_script([qw(-index -Lbasic), "$d/t1"]), 'index v1');
	ok(run_script([qw(-index -Lbasic), "$d/t2"]), 'index v2');
	my $f = "$d/t1/public-inbox/msgmap.sqlite3";
	my $ca = PublicInbox::Msgmap->new_file($f)->created_at;
	is($ca, $created{v1}, 'clone + index v1 synced ->created_at');
	$f = "$d/t2/msgmap.sqlite3";
	$ca = PublicInbox::Msgmap->new_file($f)->created_at;
	is($ca, $created{v2}, 'clone + index v1 synced ->created_at');
	test_lei(sub {
		lei_ok qw(inspect num:1 --dir), "$d/t1";
		ok(ref(json_utf8->decode($lei_out)), 'inspect num: on v1');
		lei_ok qw(inspect num:1 --dir), "$d/t2";
		ok(ref(json_utf8->decode($lei_out)), 'inspect num: on v2');
	});
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
