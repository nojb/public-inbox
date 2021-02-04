#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use File::Path qw(rmtree);
use Fcntl qw(SEEK_SET);
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
my @onions = qw(http://hjrcffqmbrq6wope.onion/meta/
	http://czquwvybam4bgbro.onion/meta/
	http://ou63pmih66umazou.onion/meta/);
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
local $ENV{FOO} = 'BAR';
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

my $setup_publicinboxes = sub {
	state $done = '';
	return if $done eq $home;
	use PublicInbox::InboxWritable;
	for my $V (1, 2) {
		run_script([qw(-init), "-V$V", "t$V",
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
		my @eml = (glob('t/*.eml'), 't/data/0001.patch');
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

my $test_external_remote = sub {
	my ($url, $k) = @_;
SKIP: {
	my $nr = 5;
	skip "$k unset", $nr if !$url;
	skip $req_sendcmd, $nr if $req_sendcmd;
	$curl or skip 'no curl', $nr;
	which('torsocks') or skip 'no torsocks', $nr if $url =~ m!\.onion/!;
	my $mid = '20140421094015.GA8962@dcvr.yhbt.net';
	my @cmd = ('q', '--only', $url, '-q', "m:$mid");
	ok($lei->(@cmd), "query $url");
	is($err, '', "no errors on $url");
	my $res = $json->decode($out);
	is($res->[0]->{'m'}, "<$mid>", "got expected mid from $url");
	ok($lei->(@cmd, 'd:..20101002'), 'no results, no error');
	is($err, '', 'no output on 404, matching local FS behavior');
	is($out, "[null]\n", 'got null results');
} # /SKIP
}; # /sub

my $test_external = sub {
	$setup_publicinboxes->();
	$cleanup->();
	$lei->('ls-external');
	is($out.$err, '', 'ls-external no output, yet');
	ok(!-e $config_file && !-e $store_dir,
		'nothing created by ls-external');

	ok(!$lei->('add-external', "$home/nonexistent"),
		"fails on non-existent dir");
	$lei->('ls-external');
	is($out.$err, '', 'ls-external still has no output');
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
	ok($lei->(qw(add-external -q https://EXAMPLE.com/ibx)), 'add remote');
	is($err, '', 'no warnings after add-external');

	ok($lei->(qw(_complete lei forget-external)), 'complete for externals');
	my %comp = map { $_ => 1 } split(/\s+/, $out);
	ok($comp{'https://example.com/ibx/'}, 'forget external completion');
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		ok($comp{$ibx->{inboxdir}}, "local $ibx->{name} completion");
	});
	for my $u (qw(h http https https: https:/ https:// https://e
			https://example https://example. https://example.co
			https://example.com https://example.com/
			https://example.com/i https://example.com/ibx)) {
		ok($lei->(qw(_complete lei forget-external), $u),
			"partial completion for URL $u");
		is($out, "https://example.com/ibx/\n",
			"completed partial URL $u");
		for my $qo (qw(-I --include --exclude --only)) {
			ok($lei->(qw(_complete lei q), $qo, $u),
				"partial completion for URL q $qo $u");
			is($out, "https://example.com/ibx/\n",
				"completed partial URL $u on q $qo");
		}
	}
	ok($lei->(qw(_complete lei add-external), 'https://'),
		'add-external hostname completion');
	is($out, "https://example.com/\n", 'completed up to hostname');

	$lei->('ls-external');
	like($out, qr!https://example\.com/ibx/!s, 'added canonical URL');
	is($err, '', 'no warnings on ls-external');
	ok($lei->(qw(forget-external -q https://EXAMPLE.com/ibx)),
		'forget');
	$lei->('ls-external');
	unlike($out, qr!https://example\.com/ibx/!s, 'removed canonical URL');

SKIP: {
	skip $req_sendcmd, 52 if $req_sendcmd;
	ok(!$lei->(qw(q s:prefix -o /dev/null -f maildir)), 'bad maildir');
	like($err, qr!/dev/null exists and is not a directory!,
		'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	ok(!$lei->(qw(q s:prefix -f mboxcl2 -o), $home), 'bad mbox');
	like($err, qr!\Q$home\E exists and is not a writable file!,
		'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	ok(!$lei->(qw(q s:prefix -o /dev/stdout -f Mbox2)), 'bad format');
	like($err, qr/bad mbox --format=mbox2/, 'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	# note, on a Bourne shell users should be able to use either:
	#	s:"use boolean prefix"
	#	"s:use boolean prefix"
	# or use single quotes, it should not matter.  Users only need
	# to know shell quoting rules, not Xapian quoting rules.
	# No double-quoting should be imposed on users on the CLI
	$lei->('q', 's:use boolean prefix');
	like($out, qr/search: use boolean prefix/, 'phrase search got result');
	my $res = $json->decode($out);
	is(scalar(@$res), 2, 'only 2 element array (1 result)');
	is($res->[1], undef, 'final element is undef'); # XXX should this be?
	is(ref($res->[0]), 'HASH', 'first element is hashref');
	$lei->('q', '--pretty', 's:use boolean prefix');
	my $pretty = $json->decode($out);
	is_deeply($res, $pretty, '--pretty is identical after decode');

	{
		open my $fh, '+>', undef or BAIL_OUT $!;
		$fh->autoflush(1);
		print $fh 's:use' or BAIL_OUT $!;
		seek($fh, 0, SEEK_SET) or BAIL_OUT $!;
		ok($lei->([qw(q -q --stdin)], undef, { %$opt, 0 => $fh }),
				'--stdin on regular file works');
		like($out, qr/use boolean prefix/, '--stdin on regular file');
	}
	{
		pipe(my ($r, $w)) or BAIL_OUT $!;
		print $w 's:use' or BAIL_OUT $!;
		close $w or BAIL_OUT $!;
		ok($lei->([qw(q -q --stdin)], undef, { %$opt, 0 => $r }),
				'--stdin on pipe file works');
		like($out, qr/use boolean prefix/, '--stdin on pipe');
	}
	ok(!$lei->(qw(q -q --stdin s:use)), "--stdin and argv don't mix");

	for my $fmt (qw(ldjson ndjson jsonl)) {
		$lei->('q', '-f', $fmt, 's:use boolean prefix');
		is($out, $json->encode($pretty->[0])."\n", "-f $fmt");
	}

	require IO::Uncompress::Gunzip;
	for my $sfx ('', '.gz') {
		my $f = "$home/mbox$sfx";
		$lei->('q', '-o', "mboxcl2:$f", 's:use boolean prefix');
		my $cat = $sfx eq '' ? sub {
			open my $mb, '<', $f or fail "no mbox: $!";
			<$mb>
		} : sub {
			my $z = IO::Uncompress::Gunzip->new($f, MultiStream=>1);
			<$z>;
		};
		my @s = grep(/^Subject:/, $cat->());
		is(scalar(@s), 1, "1 result in mbox$sfx");
		$lei->('q', '-a', '-o', "mboxcl2:$f", 's:see attachment');
		is(grep(!/^#/, $err), 0, 'no errors from augment');
		@s = grep(/^Subject:/, my @wtf = $cat->());
		is(scalar(@s), 2, "2 results in mbox$sfx");

		$lei->('q', '-a', '-o', "mboxcl2:$f", 's:nonexistent');
		is(grep(!/^#/, $err), 0, "no errors on no results ($sfx)");

		my @s2 = grep(/^Subject:/, $cat->());
		is_deeply(\@s2, \@s,
			"same 2 old results w/ --augment and bad search $sfx");

		$lei->('q', '-o', "mboxcl2:$f", 's:nonexistent');
		my @res = $cat->();
		is_deeply(\@res, [], "clobber w/o --augment $sfx");
	}
	ok(!$lei->('q', '-o', "$home/mbox", 's:nope'),
			'fails if mbox format unspecified');
	ok(!$lei->(qw(q --no-local s:see)), '--no-local');
	is($? >> 8, 1, 'proper exit code');
	like($err, qr/no local or remote.+? to search/, 'no inbox');
	my %e = (
		TEST_LEI_EXTERNAL_HTTPS => 'https://public-inbox.org/meta/',
		TEST_LEI_EXTERNAL_ONION => $onions[int(rand(scalar(@onions)))],
	);
	for my $k (keys %e) {
		my $url = $ENV{$k} // '';
		$url = $e{$k} if $url eq '1';
		$test_external_remote->($url, $k);
	}
	}; # /SKIP
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
		ok($out{$sw}, "$sw offered as completion");
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
	$test_external->();
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
