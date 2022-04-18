#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Fcntl qw(SEEK_SET);
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
use POSIX qw(WTERMSIG WIFSIGNALED SIGPIPE);

my @onions = map { "http://$_.onion/meta/" } qw(
	4uok3hntl7oi7b4uf4rtfwefqeexfzil2w6kgk2jn5z2f764irre7byd
	ie5yzdi7fg72h7s4sdcztq5evakq23rdt33mfyfcddc5u3ndnw24ogqd
	7fh6tueqddpjyxjmgtdiueylzoqt6pt7hec3pukyptlmohoowvhde4yd);

my $test_external_remote = sub {
	my ($url, $k) = @_;
SKIP: {
	skip "$k unset", 1 if !$url;
	require_cmd 'curl', 1 or skip 'curl missing', 1;
	if ($url =~ m!\.onion/!) {
		require_cmd 'torsocks', 1 or skip 'no torsocks', 1;
	}
	my $mid = '20140421094015.GA8962@dcvr.yhbt.net';
	my @cmd = ('q', '--only', $url, '-q', "m:$mid");
	lei_ok(@cmd, \"query $url");
	is($lei_err, '', "no errors on $url");
	my $res = json_utf8->decode($lei_out);
	is($res->[0]->{'m'}, $mid, "got expected mid from $url") or
		skip 'further remote tests', 1;
	lei_ok(@cmd, 'd:..20101002', \'no results, no error');
	is($lei_err, '', 'no output on 404, matching local FS behavior');
	is($lei_out, "[null]\n", 'got null results');
	my ($pid_before, $pid_after);
	if (-d $ENV{XDG_RUNTIME_DIR} && -w _) {
		lei_ok 'daemon-pid';
		chomp($pid_before = $lei_out);
		ok($pid_before, 'daemon is live');
	}
	for my $out ([], [qw(-f mboxcl2)]) {
		pipe(my ($r, $w)) or BAIL_OUT $!;
		open my $err, '+>', undef or BAIL_OUT $!;
		my $opt = { run_mode => 0, 1 => $w, 2 => $err };
		my $cmd = [qw(lei q -qt), @$out, 'z:1..'];
		my $tp = start_script($cmd, undef, $opt);
		close $w;
		sysread($r, my $buf, 1);
		close $r; # trigger SIGPIPE
		$tp->join;
		ok(WIFSIGNALED($?), "signaled @$out");
		is(WTERMSIG($?), SIGPIPE, "got SIGPIPE @$out");
		seek($err, 0, 0);
		my @err = <$err>;
		is_deeply(\@err, [], "no errors @$out");
	}
	if (-d $ENV{XDG_RUNTIME_DIR} && -w _) {
		lei_ok 'daemon-pid';
		chomp(my $pid_after = $lei_out);
		is($pid_after, $pid_before, 'pid unchanged') or
			skip 'daemon died', 1;
		skip 'not killing persistent lei-daemon', 2 if
				$ENV{TEST_LEI_DAEMON_PERSIST_DIR};
		lei_ok 'daemon-kill';
		my $alive = 1;
		for (1..100) {
			$alive = kill(0, $pid_after) or last;
			tick();
		}
		ok(!$alive, 'daemon-kill worked');
	}
} # /SKIP
}; # /sub

my ($ro_home, $cfg_path) = setup_public_inboxes;
test_lei(sub {
	my $home = $ENV{HOME};
	my $config_file = "$home/.config/lei/config";
	my $store_dir = "$home/.local/share/lei";
	lei_ok 'ls-external', \'ls-external on fresh install';
	ignore_inline_c_missing($lei_err);
	is($lei_out.$lei_err, '', 'ls-external no output, yet');
	ok(!-e $config_file && !-e $store_dir,
		'nothing created by ls-external');

	ok(!lei('add-external', "$home/nonexistent"),
		"fails on non-existent dir");
	like($lei_err, qr/not a directory/, 'noted non-existence');
	mkdir "$home/new\nline" or BAIL_OUT "mkdir: $!";
	ok(!lei('add-external', "$home/new\nline"), "fails on newline");
	like($lei_err, qr/`\\n' not allowed/, 'newline noted in error');
	lei_ok('ls-external', \'ls-external works after add failure');
	is($lei_out.$lei_err, '', 'ls-external still has no output');
	my $cfg = PublicInbox::Config->new($cfg_path);
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		lei_ok(qw(add-external -q), $ibx->{inboxdir},
				\'added external');
		is($lei_out.$lei_err, '', 'no output');
	});
	ok(-s $config_file, 'add-external created config');
	my $lcfg = PublicInbox::Config->new($config_file);
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		is($lcfg->{"external.$ibx->{inboxdir}.boost"}, 0,
			"configured boost on $ibx->{name}");
	});
	lei_ok 'ls-external';
	like($lei_out, qr/boost=0\n/s, 'ls-external has output');
	lei_ok qw(add-external -q https://EXAMPLE.com/ibx), \'add remote';
	is($lei_err, '', 'no warnings after add-external');

	{
		lei_ok qw(ls-external --remote);
		my $r_only = +{ map { $_ => 1 } split(/^/m, $lei_out) };
		lei_ok qw(ls-external --local);
		my $l_only = +{ map { $_ => 1 } split(/^/m, $lei_out) };
		lei_ok 'ls-external';
		is_deeply([grep { $l_only->{$_} } keys %$r_only], [],
			'no locals in --remote');
		is_deeply([grep { $r_only->{$_} } keys %$l_only], [],
			'no remotes in --local');
		my $all = +{ map { $_ => 1 } split(/^/m, $lei_out) };
		is_deeply($all, { %$r_only, %$l_only },
				'default output combines remote + local');
		lei_ok qw(ls-external --remote --local);
		my $both = +{ map { $_ => 1 } split(/^/m, $lei_out) };
		is_deeply($all, $both, '--remote --local == no args');
	}

	lei_ok qw(_complete lei forget-external), \'complete for externals';
	my %comp = map { $_ => 1 } split(/\s+/, $lei_out);
	ok($comp{'https://example.com/ibx/'}, 'forget external completion');
	my @dirs;
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		push @dirs, $ibx->{inboxdir};
		ok($comp{$ibx->{inboxdir}}, "local $ibx->{name} completion");
	});
	for my $u (qw(h http https https: https:/ https:// https://e
			https://example https://example. https://example.co
			https://example.com https://example.com/
			https://example.com/i https://example.com/ibx)) {
		lei_ok(qw(_complete lei forget-external), $u,
			\"partial completion for URL $u");
		is($lei_out, "https://example.com/ibx/\n",
			"completed partial URL $u");
		for my $qo (qw(-I --include --exclude --only)) {
			lei_ok(qw(_complete lei q), $qo, $u,
				\"partial completion for URL q $qo $u");
			is($lei_out, "https://example.com/ibx/\n",
				"completed partial URL $u on q $qo");
		}
	}
	lei_ok(qw(_complete lei add-external), 'https://',
		\'add-external hostname completion');
	is($lei_out, "https://example.com/\n", 'completed up to hostname');

	lei_ok('ls-external');
	like($lei_out, qr!https://example\.com/ibx/!s, 'added canonical URL');
	is($lei_err, '', 'no warnings on ls-external');
	lei_ok(qw(forget-external -q https://EXAMPLE.com/ibx));
	lei_ok('ls-external');
	unlike($lei_out, qr!https://example\.com/ibx/!s,
		'removed canonical URL');

	# do some queries
	ok(!lei(qw(q s:prefix -o maildir:/dev/null)), 'bad maildir');
	like($lei_err, qr!/dev/null exists and is not a directory!,
		'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	ok(!lei(qw(q s:prefix -o), "mboxcl2:$home"), 'bad mbox');
	like($lei_err, qr!\Q$home\E exists and is not a writable file!,
		'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	ok(!lei(qw(q s:prefix -o Mbox2:/dev/stdout)), 'bad format');
	like($lei_err, qr/bad mbox format: mbox2/, 'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	# note, on a Bourne shell users should be able to use either:
	#	s:"use boolean prefix"
	#	"s:use boolean prefix"
	# or use single quotes, it should not matter.  Users only need
	# to know shell quoting rules, not Xapian quoting rules.
	# No double-quoting should be imposed on users on the CLI
	lei_ok('q', 's:use boolean prefix');
	like($lei_out, qr/search: use boolean prefix/,
		'phrase search got result');
	my $res = json_utf8->decode($lei_out);
	is(scalar(@$res), 2, 'only 2 element array (1 result)');
	is($res->[1], undef, 'final element is undef'); # XXX should this be?
	is(ref($res->[0]), 'HASH', 'first element is hashref');
	lei_ok('q', '--pretty', 's:use boolean prefix');
	my $pretty = json_utf8->decode($lei_out);
	is_deeply($res, $pretty, '--pretty is identical after decode');

	{
		open my $fh, '+>', undef or BAIL_OUT $!;
		$fh->autoflush(1);
		print $fh 's:use d:..5.days.from.now' or BAIL_OUT $!;
		seek($fh, 0, SEEK_SET) or BAIL_OUT $!;
		lei_ok([qw(q -q --stdin)], undef, { %$lei_opt, 0 => $fh },
				\'--stdin on regular file works');
		like($lei_out, qr/use boolean/, '--stdin on regular file');
	}
	{
		pipe(my ($r, $w)) or BAIL_OUT $!;
		print $w 's:use' or BAIL_OUT $!;
		close $w or BAIL_OUT $!;
		lei_ok([qw(q -q --stdin)], undef, { %$lei_opt, 0 => $r },
				\'--stdin on pipe file works');
		like($lei_out, qr/use boolean prefix/, '--stdin on pipe');
	}
	ok(!lei(qw(q -q --stdin s:use)), "--stdin and argv don't mix");
	like($lei_err, qr/no query allowed.*--stdin/,
		'--stdin conflict error message');

	for my $fmt (qw(ldjson ndjson jsonl)) {
		lei_ok('q', '-f', $fmt, 's:use boolean prefix');
		is($lei_out, json_utf8->encode($pretty->[0])."\n", "-f $fmt");
	}

	require IO::Uncompress::Gunzip;
	for my $sfx ('', '.gz') {
		my $f = "$home/mbox$sfx";
		lei_ok('q', '-o', "mboxcl2:$f", 's:use boolean prefix');
		my $cat = $sfx eq '' ? sub {
			open my $mb, '<', $f or fail "no mbox: $!";
			<$mb>
		} : sub {
			my $z = IO::Uncompress::Gunzip->new($f, MultiStream=>1);
			<$z>;
		};
		my @s = grep(/^Subject:/, $cat->());
		is(scalar(@s), 1, "1 result in mbox$sfx");
		lei_ok('q', '-a', '-o', "mboxcl2:$f", 's:see attachment');
		is(grep(!/^#/, $lei_err), 0, 'no errors from augment') or
			diag $lei_err;
		@s = grep(/^Subject:/, my @wtf = $cat->());
		is(scalar(@s), 2, "2 results in mbox$sfx");

		lei_ok('q', '-a', '-o', "mboxcl2:$f", 's:nonexistent');
		is(grep(!/^#/, $lei_err), 0, "no errors on no results ($sfx)")
			or diag $lei_err;

		my @s2 = grep(/^Subject:/, $cat->());
		is_deeply(\@s2, \@s,
			"same 2 old results w/ --augment and bad search $sfx");

		lei_ok('q', '-o', "mboxcl2:$f", 's:nonexistent');
		my @res = $cat->();
		is_deeply(\@res, [], "clobber w/o --augment $sfx");
	}
	ok(!lei('q', '-o', "$home/mbox", 's:nope'),
			'fails if mbox format unspecified');
	like($lei_err, qr/unable to determine mbox/, 'mbox-related message');

	ok(!lei(qw(q --no-local s:see)), '--no-local');
	is($? >> 8, 1, 'proper exit code');
	like($lei_err, qr/no local or remote.+? to search/, 'no inbox');

	for my $no (['--no-local'], ['--no-external'],
			[qw(--no-local --no-external)]) {
		lei_ok(qw(q mid:testmessage@example.com), @$no,
			'-I', $dirs[0], \"-I and @$no combine");
		$res = json_utf8->decode($lei_out);
		is($res->[0]->{'m'}, 'testmessage@example.com',
			"-I \$DIR got results regardless of @$no");
	}

	{
		skip 'TEST_LEI_DAEMON_PERSIST_DIR in use', 1 if
					$ENV{TEST_LEI_DAEMON_PERSIST_DIR};
		my @q = qw(q -o mboxcl2:rel.mboxcl2 bye);
		lei_ok('-C', $home, @q);
		is(unlink("$home/rel.mboxcl2"), 1, '-C works before q');

		# we are more flexible than git, here:
		lei_ok(@q, '-C', $home);
		is(unlink("$home/rel.mboxcl2"), 1, '-C works after q');
		mkdir "$home/deep" or BAIL_OUT $!;
		lei_ok('-C', $home, @q, '-C', 'deep');
		is(unlink("$home/deep/rel.mboxcl2"), 1, 'multiple -C works');

		lei_ok('-C', '', '-C', $home, @q, '-C', 'deep', '-C', '');
		is(unlink("$home/deep/rel.mboxcl2"), 1, "-C '' accepted");
		ok(!-f "$home/rel.mboxcl2", 'wrong path not created');
	}
	my %e = (
		TEST_LEI_EXTERNAL_HTTPS => 'https://public-inbox.org/meta/',
		TEST_LEI_EXTERNAL_ONION => $onions[int(rand(scalar(@onions)))],
	);
	for my $k (keys %e) {
		my $url = $ENV{$k} // '';
		$url = $e{$k} if $url eq '1';
		$test_external_remote->($url, $k);
	}
}); # test_lei
done_testing;
