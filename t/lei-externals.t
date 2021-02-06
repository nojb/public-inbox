#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use Fcntl qw(SEEK_SET);
use PublicInbox::Spawn qw(which);

my @onions = qw(http://hjrcffqmbrq6wope.onion/meta/
	http://czquwvybam4bgbro.onion/meta/
	http://ou63pmih66umazou.onion/meta/);

# TODO share this across tests, it takes ~300ms
my $setup_publicinboxes = sub {
	my ($home) = @_;
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
	$seen || BAIL_OUT 'no imports';
};

my $test_external_remote = sub {
	my ($url, $k) = @_;
SKIP: {
	my $nr = 5;
	skip "$k unset", $nr if !$url;
	which('curl') or skip 'no curl', $nr;
	which('torsocks') or skip 'no torsocks', $nr if $url =~ m!\.onion/!;
	my $mid = '20140421094015.GA8962@dcvr.yhbt.net';
	my @cmd = ('q', '--only', $url, '-q', "m:$mid");
	ok($lei->(@cmd), "query $url");
	is($lei_err, '', "no errors on $url");
	my $res = json_utf8->decode($lei_out);
	is($res->[0]->{'m'}, "<$mid>", "got expected mid from $url");
	ok($lei->(@cmd, 'd:..20101002'), 'no results, no error');
	is($lei_err, '', 'no output on 404, matching local FS behavior');
	is($lei_out, "[null]\n", 'got null results');
} # /SKIP
}; # /sub

test_lei(sub {
	my $home = $ENV{HOME};
	$setup_publicinboxes->($home);
	my $config_file = "$home/.config/lei/config";
	my $store_dir = "$home/.local/share/lei";
	ok($lei->('ls-external'), 'ls-external works');
	is($lei_out.$lei_err, '', 'ls-external no output, yet');
	ok(!-e $config_file && !-e $store_dir,
		'nothing created by ls-external');

	ok(!$lei->('add-external', "$home/nonexistent"),
		"fails on non-existent dir");
	ok($lei->('ls-external'), 'ls-external works after add failure');
	is($lei_out.$lei_err, '', 'ls-external still has no output');
	my $cfg = PublicInbox::Config->new;
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		ok($lei->(qw(add-external -q), $ibx->{inboxdir}),
			'added external');
		is($lei_out.$lei_err, '', 'no output');
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
	like($lei_out, qr/boost=0\n/s, 'ls-external has output');
	ok($lei->(qw(add-external -q https://EXAMPLE.com/ibx)), 'add remote');
	is($lei_err, '', 'no warnings after add-external');

	ok($lei->(qw(_complete lei forget-external)), 'complete for externals');
	my %comp = map { $_ => 1 } split(/\s+/, $lei_out);
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
		is($lei_out, "https://example.com/ibx/\n",
			"completed partial URL $u");
		for my $qo (qw(-I --include --exclude --only)) {
			ok($lei->(qw(_complete lei q), $qo, $u),
				"partial completion for URL q $qo $u");
			is($lei_out, "https://example.com/ibx/\n",
				"completed partial URL $u on q $qo");
		}
	}
	ok($lei->(qw(_complete lei add-external), 'https://'),
		'add-external hostname completion');
	is($lei_out, "https://example.com/\n", 'completed up to hostname');

	$lei->('ls-external');
	like($lei_out, qr!https://example\.com/ibx/!s, 'added canonical URL');
	is($lei_err, '', 'no warnings on ls-external');
	ok($lei->(qw(forget-external -q https://EXAMPLE.com/ibx)),
		'forget');
	$lei->('ls-external');
	unlike($lei_out, qr!https://example\.com/ibx/!s,
		'removed canonical URL');
SKIP: {
	ok(!$lei->(qw(q s:prefix -o /dev/null -f maildir)), 'bad maildir');
	like($lei_err, qr!/dev/null exists and is not a directory!,
		'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	ok(!$lei->(qw(q s:prefix -f mboxcl2 -o), $home), 'bad mbox');
	like($lei_err, qr!\Q$home\E exists and is not a writable file!,
		'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	ok(!$lei->(qw(q s:prefix -o /dev/stdout -f Mbox2)), 'bad format');
	like($lei_err, qr/bad mbox --format=mbox2/, 'error shown');
	is($? >> 8, 1, 'errored out with exit 1');

	# note, on a Bourne shell users should be able to use either:
	#	s:"use boolean prefix"
	#	"s:use boolean prefix"
	# or use single quotes, it should not matter.  Users only need
	# to know shell quoting rules, not Xapian quoting rules.
	# No double-quoting should be imposed on users on the CLI
	$lei->('q', 's:use boolean prefix');
	like($lei_out, qr/search: use boolean prefix/,
		'phrase search got result');
	my $res = json_utf8->decode($lei_out);
	is(scalar(@$res), 2, 'only 2 element array (1 result)');
	is($res->[1], undef, 'final element is undef'); # XXX should this be?
	is(ref($res->[0]), 'HASH', 'first element is hashref');
	$lei->('q', '--pretty', 's:use boolean prefix');
	my $pretty = json_utf8->decode($lei_out);
	is_deeply($res, $pretty, '--pretty is identical after decode');

	{
		open my $fh, '+>', undef or BAIL_OUT $!;
		$fh->autoflush(1);
		print $fh 's:use' or BAIL_OUT $!;
		seek($fh, 0, SEEK_SET) or BAIL_OUT $!;
		ok($lei->([qw(q -q --stdin)], undef, { %$lei_opt, 0 => $fh }),
				'--stdin on regular file works');
		like($lei_out, qr/use boolean/, '--stdin on regular file');
	}
	{
		pipe(my ($r, $w)) or BAIL_OUT $!;
		print $w 's:use' or BAIL_OUT $!;
		close $w or BAIL_OUT $!;
		ok($lei->([qw(q -q --stdin)], undef, { %$lei_opt, 0 => $r }),
				'--stdin on pipe file works');
		like($lei_out, qr/use boolean prefix/, '--stdin on pipe');
	}
	ok(!$lei->(qw(q -q --stdin s:use)), "--stdin and argv don't mix");

	for my $fmt (qw(ldjson ndjson jsonl)) {
		$lei->('q', '-f', $fmt, 's:use boolean prefix');
		is($lei_out, json_utf8->encode($pretty->[0])."\n", "-f $fmt");
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
		is(grep(!/^#/, $lei_err), 0, 'no errors from augment');
		@s = grep(/^Subject:/, my @wtf = $cat->());
		is(scalar(@s), 2, "2 results in mbox$sfx");

		$lei->('q', '-a', '-o', "mboxcl2:$f", 's:nonexistent');
		is(grep(!/^#/, $lei_err), 0, "no errors on no results ($sfx)");

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
	like($lei_err, qr/no local or remote.+? to search/, 'no inbox');
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
}); # test_lei
done_testing;
