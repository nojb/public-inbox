#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use File::Path qw(rmtree);
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
my $opt = { 1 => \(my $out = ''), 2 => \(my $err = '') };
my $lei = sub {
	my ($cmd, $env, $xopt) = @_;
	$out = $err = '';
	if (!ref($cmd)) {
		($env, $xopt) = grep { (!defined) || ref } @_;
		$cmd = [ grep { defined && !ref } @_ ];
	}
	run_script(['lei', @$cmd], $env, $xopt // $opt);
};

my ($home, $for_destroy) = tmpdir();
delete local $ENV{XDG_DATA_HOME};
delete local $ENV{XDG_CONFIG_HOME};
local $ENV{GIT_COMMITTER_EMAIL} = 'lei@example.com';
local $ENV{GIT_COMMITTER_NAME} = 'lei user';
local $ENV{XDG_RUNTIME_DIR} = "$home/xdg_run";
local $ENV{HOME} = $home;
local $ENV{FOO} = 'BAR';
mkdir "$home/xdg_run", 0700 or BAIL_OUT "mkdir: $!";
my $home_trash = [ "$home/.local", "$home/.config" ];
my $cleanup = sub { rmtree([@$home_trash, @_]) };
my $config_file = "$home/.config/lei/config";
my $store_dir = "$home/.local/share/lei";

my $test_help = sub {
	ok(!$lei->([], undef, $opt), 'no args fails');
	is($? >> 8, 1, '$? is 1');
	is($out, '', 'nothing in stdout');
	like($err, qr/^usage:/sm, 'usage in stderr');

	for my $arg (['-h'], ['--help'], ['help'], [qw(daemon-pid --help)]) {
		$out = $err = '';
		ok($lei->($arg, undef, $opt), "lei @$arg");
		like($out, qr/^usage:/sm, "usage in stdout (@$arg)");
		is($err, '', "nothing in stderr (@$arg)");
	}

	for my $arg ([''], ['--halp'], ['halp'], [qw(daemon-pid --halp)]) {
		$out = $err = '';
		ok(!$lei->($arg, undef, $opt), "lei @$arg");
		is($? >> 8, 1, '$? set correctly');
		isnt($err, '', 'something in stderr');
		is($out, '', 'nothing in stdout');
	}
	ok($lei->(qw(init -h), undef, $opt), 'init -h');
	like($out, qr! \Q$home\E/\.local/share/lei/store\b!,
		'actual path shown in init -h');
	ok($lei->(qw(init -h), { XDG_DATA_HOME => '/XDH' }, $opt),
		'init with XDG_DATA_HOME');
	like($out, qr! /XDH/lei/store\b!, 'XDG_DATA_HOME in init -h');
	is($err, '', 'no errors from init -h');

	ok($lei->(qw(config -h), undef, $opt), 'config-h');
	like($out, qr! \Q$home\E/\.config/lei/config\b!,
		'actual path shown in config -h');
	ok($lei->(qw(config -h), { XDG_CONFIG_HOME => '/XDC' }, $opt),
		'config with XDG_CONFIG_HOME');
	like($out, qr! /XDC/lei/config\b!, 'XDG_CONFIG_HOME in config -h');
	is($err, '', 'no errors from config -h');
};

my $ok_err_info = sub {
	my ($msg) = @_;
	is(grep(!/^I:/, split(/^/, $err)), 0, $msg) or
		diag "$msg: err=$err";
	$err = '';
};

my $test_init = sub {
	$cleanup->();
	ok($lei->(['init'], undef, $opt), 'init w/o args');
	$ok_err_info->('after init w/o args');
	ok($lei->(['init'], undef, $opt), 'idempotent init w/o args');
	$ok_err_info->('after idempotent init w/o args');

	ok(!$lei->(['init', "$home/x"], undef, $opt),
		'init conflict');
	is(grep(/^E:/, split(/^/, $err)), 1, 'got error on conflict');
	ok(!-e "$home/x", 'nothing created on conflict');
	$cleanup->();

	ok($lei->(['init', "$home/x"], undef, $opt), 'init conflict resolved');
	$ok_err_info->('init w/ arg');
	ok($lei->(['init', "$home/x"], undef, $opt), 'init idempotent w/ path');
	$ok_err_info->('init idempotent w/ arg');
	ok(-d "$home/x", 'created dir');
	$cleanup->("$home/x");

	ok(!$lei->(['init', "$home/x", "$home/2" ], undef, $opt),
		'too many args fails');
	like($err, qr/too many/, 'noted excessive');
	ok(!-e "$home/x", 'x not created on excessive');
	for my $d (@$home_trash) {
		my $base = (split(m!/!, $d))[-1];
		ok(!-d $d, "$base not created");
	}
	is($out, '', 'nothing in stdout on init failure');
};

my $test_config = sub {
	$cleanup->();
	ok($lei->([qw(config a.b c)], undef, $opt), 'config set var');
	is($out.$err, '', 'no output on var set');
	ok($lei->([qw(config -l)], undef, $opt), 'config -l');
	is($err, '', 'no errors on listing');
	is($out, "a.b=c\n", 'got expected output');
	ok(!$lei->([qw(config -f), "$home/.config/f", qw(x.y z)], undef, $opt),
			'config set var with -f fails');
	like($err, qr/not supported/, 'not supported noted');
	ok(!-f "$home/config/f", 'no file created');
};

my $setup_publicinboxes = sub {
	state $done = '';
	return if $done eq $home;
	use PublicInbox::InboxWritable;
	for my $V (1, 2) {
		run_script([qw(-init -Lmedium), "-V$V", "t$V",
				'--newsgroup', "t.$V",
				"$home/t$V", "http://example.com/t$V",
				"t$V\@example.com" ]) or BAIL_OUT "init v$V";
	}
	my $cfg = PublicInbox::Config->new;
	my $seen = 0;
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		my $im = PublicInbox::InboxWritable->new($ibx)->importer(0);
		my $V = $ibx->version;
		my @eml = glob('t/*.eml');
		push(@eml, 't/data/0001.patch') if $V == 2;
		for (@eml) {
			next if $_ eq 't/psgi_v2-old.eml'; # dup mid
			$im->add(eml_load($_)) or BAIL_OUT "v$V add $_";
			$seen++;
		}
		$im->done;
		if ($V == 1) {
			run_script(['-index', $ibx->{inboxdir}]) or
				BAIL_OUT 'index v1';
		}
	});
	$done = $home;
	$seen || BAIL_OUT 'no imports';
};

my $test_external = sub {
	$setup_publicinboxes->();
	$cleanup->();
	$lei->('ls-external');
	is($out.$err, '', 'ls-external no output, yet');
	ok(!-e $config_file && !-e $store_dir,
		'nothing created by ls-external');

	my $cfg = PublicInbox::Config->new;
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		ok($lei->(qw(add-external -q), $ibx->{inboxdir}),
			'added external');
		is($out.$err, '', 'no output');
	});
	ok(-s $config_file && -e $store_dir,
		'add-external created config + store');
	my $lcfg = PublicInbox::Config->new($config_file);
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		is($lcfg->{"external.$ibx->{inboxdir}.boost"}, 0,
			"configured boost on $ibx->{name}");
	});
	$lei->('ls-external');
	like($out, qr/boost=0\n/s, 'ls-external has output');
};

my $test_lei_common = sub {
	$test_help->();
	$test_config->();
	$test_init->();
	$test_external->();
};

if ($ENV{TEST_LEI_ONESHOT}) {
	require_ok 'PublicInbox::LEI';
	# force sun_path[108] overflow, "IO::FDPass" avoids warning
	local $ENV{XDG_RUNTIME_DIR} = "$home/IO::FDPass".('.sun_path' x 108);
	$test_lei_common->();
}

SKIP: { # real socket
	require_mods(qw(IO::FDPass Cwd), 46);
	local $ENV{XDG_RUNTIME_DIR} = "$home/xdg_run";
	my $sock = "$ENV{XDG_RUNTIME_DIR}/lei/sock";

	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	is($err, '', 'no error from daemon-pid');
	like($out, qr/\A[0-9]+\n\z/s, 'pid returned') or BAIL_OUT;
	chomp(my $pid = $out);
	ok(kill(0, $pid), 'pid is valid');
	ok(-S $sock, 'sock created');

	$test_lei_common->();

	$out = '';
	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	chomp(my $pid_again = $out);
	is($pid, $pid_again, 'daemon-pid idempotent');

	$out = '';
	ok(run_script([qw(lei daemon-env -0)], undef, $opt), 'show env');
	is($err, '', 'no errors in env dump');
	my @env = split(/\0/, $out);
	is(scalar grep(/\AHOME=\Q$home\E\z/, @env), 1, 'env has HOME');
	is(scalar grep(/\AFOO=BAR\z/, @env), 1, 'env has FOO=BAR');
	is(scalar grep(/\AXDG_RUNTIME_DIR=/, @env), 1, 'has XDG_RUNTIME_DIR');

	$out = '';
	ok(run_script([qw(lei daemon-env -u FOO)], undef, $opt), 'unset');
	is($out.$err, '', 'no output for unset');
	ok(run_script([qw(lei daemon-env -0)], undef, $opt), 'show again');
	is($err, '', 'no errors in env dump');
	@env = split(/\0/, $out);
	is(scalar grep(/\AFOO=BAR\z/, @env), 0, 'env unset FOO');

	$out = '';
	ok(run_script([qw(lei daemon-env -u FOO -u HOME -u XDG_RUNTIME_DIR)],
			undef, $opt), 'unset multiple');
	is($out.$err, '', 'no errors output for unset');
	ok(run_script([qw(lei daemon-env -0)], undef, $opt), 'show again');
	is($err, '', 'no errors in env dump');
	@env = split(/\0/, $out);
	is(scalar grep(/\A(?:HOME|XDG_RUNTIME_DIR)=\z/, @env), 0, 'env unset@');
	$out = '';
	ok(run_script([qw(lei daemon-env -)], undef, $opt), 'clear env');
	is($out.$err, '', 'no output');
	ok(run_script([qw(lei daemon-env)], undef, $opt), 'env is empty');
	is($out, '', 'env cleared');

	ok(run_script([qw(lei daemon-kill)], undef, $opt), 'daemon-kill');
	is($out, '', 'no output from daemon-kill');
	is($err, '', 'no error from daemon-kill');
	for (0..100) {
		kill(0, $pid) or last;
		tick();
	}
	ok(!-S $sock, 'sock gone');
	ok(!kill(0, $pid), 'pid gone after stop');

	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	chomp(my $new_pid = $out);
	ok(kill(0, $new_pid), 'new pid is running');
	ok(-S $sock, 'sock exists again');

	$out = $err = '';
	for my $sig (qw(-0 -CHLD)) {
		ok(run_script([qw(lei daemon-kill), $sig ], undef, $opt),
					"handles $sig");
	}
	is($out.$err, '', 'no output on innocuous signals');
	ok(run_script([qw(lei daemon-pid)], undef, $opt), 'daemon-pid');
	chomp $out;
	is($out, $new_pid, 'PID unchanged after -0/-CHLD');

	if ('socket inaccessible') {
		chmod 0000, $sock or BAIL_OUT "chmod 0000: $!";
		$out = $err = '';
		ok(run_script([qw(lei help)], undef, $opt),
			'connect fail, one-shot fallback works');
		like($err, qr/\bconnect\(/, 'connect error noted');
		like($out, qr/^usage: /, 'help output works');
		chmod 0700, $sock or BAIL_OUT "chmod 0700: $!";
	}
	if ('oneshot on cwd gone') {
		my $cwd = Cwd::fastcwd() or BAIL_OUT "fastcwd: $!";
		my $d = "$home/to-be-removed";
		my $lei_path = 'lei';
		# we chdir, so we need an abs_path fur run_script
		if (($ENV{TEST_RUN_MODE}//2) != 2) {
			$lei_path = PublicInbox::TestCommon::key2script('lei');
			$lei_path = Cwd::abs_path($lei_path);
		}
		mkdir $d or BAIL_OUT "mkdir($d) $!";
		chdir $d or BAIL_OUT "chdir($d) $!";
		if (rmdir($d)) {
			$out = $err = '';
			ok(run_script([$lei_path, 'help'], undef, $opt),
				'cwd fail, one-shot fallback works');
		} else {
			$err = "rmdir=$!";
		}
		chdir $cwd or BAIL_OUT "chdir($cwd) $!";
		like($err, qr/cwd\(/, 'cwd error noted');
		like($out, qr/^usage: /, 'help output still works');
	}

	unlink $sock or BAIL_OUT "unlink($sock) $!";
	for (0..100) {
		kill('CHLD', $new_pid) or last;
		tick();
	}
	ok(!kill(0, $new_pid), 'daemon exits after unlink');
	# success over socket, can't test without
};

done_testing;
