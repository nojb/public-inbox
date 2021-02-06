#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use File::Path qw(rmtree);
use PublicInbox::Spawn qw(which);
my $req_sendcmd = 'Socket::MsgHdr or Inline::C missing or unconfigured';
undef($req_sendcmd) if PublicInbox::Spawn->can('send_cmd4');
eval { require Socket::MsgHdr; undef $req_sendcmd };
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
my $opt = { 1 => \(my $out = ''), 2 => \(my $err = '') };
my ($home, $for_destroy) = tmpdir();
my $err_filter;
my $curl = which('curl');
my $json = ref(PublicInbox::Config->json)->new->utf8->canonical;
my $lei = sub {
	my ($cmd, $env, $xopt) = @_;
	$out = $err = '';
	if (!ref($cmd)) {
		($env, $xopt) = grep { (!defined) || ref } @_;
		$cmd = [ grep { defined && !ref } @_ ];
	}
	my $res = run_script(['lei', @$cmd], $env, $xopt // $opt);
	$err_filter and
		$err = join('', grep(!/$err_filter/, split(/^/m, $err)));
	$res;
};

delete local $ENV{XDG_DATA_HOME};
delete local $ENV{XDG_CONFIG_HOME};
local $ENV{GIT_COMMITTER_EMAIL} = 'lei@example.com';
local $ENV{GIT_COMMITTER_NAME} = 'lei user';
local $ENV{XDG_RUNTIME_DIR} = "$home/xdg_run";
local $ENV{HOME} = $home;
mkdir "$home/xdg_run", 0700 or BAIL_OUT "mkdir: $!";
my $home_trash = [ "$home/.local", "$home/.config", "$home/junk" ];
my $cleanup = sub { rmtree([@$home_trash, @_]) };
my $config_file = "$home/.config/lei/config";
my $store_dir = "$home/.local/share/lei";

my $test_help = sub {
	ok(!$lei->(), 'no args fails');
	is($? >> 8, 1, '$? is 1');
	is($out, '', 'nothing in stdout');
	like($err, qr/^usage:/sm, 'usage in stderr');

	for my $arg (['-h'], ['--help'], ['help'], [qw(daemon-pid --help)]) {
		ok($lei->($arg), "lei @$arg");
		like($out, qr/^usage:/sm, "usage in stdout (@$arg)");
		is($err, '', "nothing in stderr (@$arg)");
	}

	for my $arg ([''], ['--halp'], ['halp'], [qw(daemon-pid --halp)]) {
		ok(!$lei->($arg), "lei @$arg");
		is($? >> 8, 1, '$? set correctly');
		isnt($err, '', 'something in stderr');
		is($out, '', 'nothing in stdout');
	}
	ok($lei->(qw(init -h)), 'init -h');
	like($out, qr! \Q$home\E/\.local/share/lei/store\b!,
		'actual path shown in init -h');
	ok($lei->(qw(init -h), { XDG_DATA_HOME => '/XDH' }),
		'init with XDG_DATA_HOME');
	like($out, qr! /XDH/lei/store\b!, 'XDG_DATA_HOME in init -h');
	is($err, '', 'no errors from init -h');

	ok($lei->(qw(config -h)), 'config-h');
	like($out, qr! \Q$home\E/\.config/lei/config\b!,
		'actual path shown in config -h');
	ok($lei->(qw(config -h), { XDG_CONFIG_HOME => '/XDC' }),
		'config with XDG_CONFIG_HOME');
	like($out, qr! /XDC/lei/config\b!, 'XDG_CONFIG_HOME in config -h');
	is($err, '', 'no errors from config -h');
};

my $ok_err_info = sub {
	my ($msg) = @_;
	is(grep(!/^I:/, split(/^/, $err)), 0, $msg) or
		diag "$msg: err=$err";
};

my $test_init = sub {
	$cleanup->();
	ok($lei->('init'), 'init w/o args');
	$ok_err_info->('after init w/o args');
	ok($lei->('init'), 'idempotent init w/o args');
	$ok_err_info->('after idempotent init w/o args');

	ok(!$lei->('init', "$home/x"), 'init conflict');
	is(grep(/^E:/, split(/^/, $err)), 1, 'got error on conflict');
	ok(!-e "$home/x", 'nothing created on conflict');
	$cleanup->();

	ok($lei->('init', "$home/x"), 'init conflict resolved');
	$ok_err_info->('init w/ arg');
	ok($lei->('init', "$home/x"), 'init idempotent w/ path');
	$ok_err_info->('init idempotent w/ arg');
	ok(-d "$home/x", 'created dir');
	$cleanup->("$home/x");

	ok(!$lei->('init', "$home/x", "$home/2"), 'too many args fails');
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
	ok($lei->(qw(config a.b c)), 'config set var');
	is($out.$err, '', 'no output on var set');
	ok($lei->(qw(config -l)), 'config -l');
	is($err, '', 'no errors on listing');
	is($out, "a.b=c\n", 'got expected output');
	ok(!$lei->(qw(config -f), "$home/.config/f", qw(x.y z)),
			'config set var with -f fails');
	like($err, qr/not supported/, 'not supported noted');
	ok(!-f "$home/config/f", 'no file created');
};

my $test_completion = sub {
	ok($lei->(qw(_complete lei)), 'no errors on complete');
	my %out = map { $_ => 1 } split(/\s+/s, $out);
	ok($out{'q'}, "`lei q' offered as completion");
	ok($out{'add-external'}, "`lei add-external' offered as completion");

	ok($lei->(qw(_complete lei q)), 'complete q (no args)');
	%out = map { $_ => 1 } split(/\s+/s, $out);
	for my $sw (qw(-f --format -o --output --mfolder --augment -a
			--mua --mua-cmd --no-local --local --verbose -v
			--save-as --no-remote --remote --torsocks
			--reverse -r )) {
		ok($out{$sw}, "$sw offered as `lei q' completion");
	}

	ok($lei->(qw(_complete lei q --form)), 'complete q --format');
	is($out, "--format\n", 'complete lei q --format');
	for my $sw (qw(-f --format)) {
		ok($lei->(qw(_complete lei q), $sw), "complete q $sw ARG");
		%out = map { $_ => 1 } split(/\s+/s, $out);
		for my $f (qw(mboxrd mboxcl2 mboxcl mboxo json jsonl
				concatjson maildir)) {
			ok($out{$f}, "got $sw $f as output format");
		}
	}
	ok($lei->(qw(_complete lei import)), 'complete import');
	%out = map { $_ => 1 } split(/\s+/s, $out);
	for my $sw (qw(--flags --no-flags --no-kw --kw --no-keywords
			--keywords)) {
		ok($out{$sw}, "$sw offered as `lei import' completion");
	}
};

my $test_fail = sub {
SKIP: {
	skip $req_sendcmd, 3 if $req_sendcmd;
	$lei->(qw(q --only http://127.0.0.1:99999/bogus/ t:m));
	is($? >> 8, 3, 'got curl exit for bogus URL');
	$lei->(qw(q --only http://127.0.0.1:99999/bogus/ t:m -o), "$home/junk");
	is($? >> 8, 3, 'got curl exit for bogus URL with Maildir');
	is($out, '', 'no output');
}; # /SKIP
};

my $test_lei_common = sub {
	$test_help->();
	$test_config->();
	$test_init->();
	$test_completion->();
	$test_fail->();
};

if ($ENV{TEST_LEI_ONESHOT}) {
	require_ok 'PublicInbox::LEI';
	# force sun_path[108] overflow, ($lei->() filters out this path)
	my $xrd = "$home/1shot-test".('.sun_path' x 108);
	local $ENV{XDG_RUNTIME_DIR} = $xrd;
	$err_filter = qr!\Q$xrd!;
	$test_lei_common->();
} else {
SKIP: { # real socket
	skip $req_sendcmd, 115 if $req_sendcmd;
	local $ENV{XDG_RUNTIME_DIR} = "$home/xdg_run";
	my $sock = "$ENV{XDG_RUNTIME_DIR}/lei/5.seq.sock";
	my $err_log = "$ENV{XDG_RUNTIME_DIR}/lei/errors.log";

	ok($lei->('daemon-pid'), 'daemon-pid');
	is($err, '', 'no error from daemon-pid');
	like($out, qr/\A[0-9]+\n\z/s, 'pid returned') or BAIL_OUT;
	chomp(my $pid = $out);
	ok(kill(0, $pid), 'pid is valid');
	ok(-S $sock, 'sock created');

	$test_lei_common->();
	is(-s $err_log, 0, 'nothing in errors.log');
	open my $efh, '>>', $err_log or BAIL_OUT $!;
	print $efh "phail\n" or BAIL_OUT $!;
	close $efh or BAIL_OUT $!;

	ok($lei->('daemon-pid'), 'daemon-pid');
	chomp(my $pid_again = $out);
	is($pid, $pid_again, 'daemon-pid idempotent');
	like($err, qr/phail/, 'got mock "phail" error previous run');

	ok($lei->(qw(daemon-kill)), 'daemon-kill');
	is($out, '', 'no output from daemon-kill');
	is($err, '', 'no error from daemon-kill');
	for (0..100) {
		kill(0, $pid) or last;
		tick();
	}
	ok(-S $sock, 'sock still exists');
	ok(!kill(0, $pid), 'pid gone after stop');

	ok($lei->(qw(daemon-pid)), 'daemon-pid');
	chomp(my $new_pid = $out);
	ok(kill(0, $new_pid), 'new pid is running');
	ok(-S $sock, 'sock still exists');

	for my $sig (qw(-0 -CHLD)) {
		ok($lei->('daemon-kill', $sig), "handles $sig");
	}
	is($out.$err, '', 'no output on innocuous signals');
	ok($lei->('daemon-pid'), 'daemon-pid');
	chomp $out;
	is($out, $new_pid, 'PID unchanged after -0/-CHLD');

	if ('socket inaccessible') {
		chmod 0000, $sock or BAIL_OUT "chmod 0000: $!";
		ok($lei->('help'), 'connect fail, one-shot fallback works');
		like($err, qr/\bconnect\(/, 'connect error noted');
		like($out, qr/^usage: /, 'help output works');
		chmod 0700, $sock or BAIL_OUT "chmod 0700: $!";
	}
	unlink $sock or BAIL_OUT "unlink($sock) $!";
	for (0..100) {
		kill('CHLD', $new_pid) or last;
		tick();
	}
	ok(!kill(0, $new_pid), 'daemon exits after unlink');
	# success over socket, can't test without
}; # SKIP
} # else

done_testing;
