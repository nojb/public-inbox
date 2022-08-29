#!perl -w
# Copyright (C)  all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use Cwd qw(abs_path);
require_git(2.6);
use PublicInbox::ContentHash qw(git_sha);
use PublicInbox::Spawn qw(popen_rd);
require_mods(qw(DBD::SQLite Search::Xapian Plack::Util));
my $git_dir = xqx([qw(git rev-parse --git-dir)], undef, {2 => \(my $null)});
$? == 0 or plan skip_all => "$0 must be run from a git working tree";
chomp $git_dir;

# needed for alternates, and --absolute-git-dir is only in git 2.13+
$git_dir = abs_path($git_dir);

use_ok "PublicInbox::$_" for (qw(Inbox V2Writable Git SolverGit WWW));
my $patch2 = eml_load 't/solve/0002-rename-with-modifications.patch';
my $patch2_oid = git_sha(1, $patch2)->hexdigest;

my ($tmpdir, $for_destroy) = tmpdir();
my $ibx = create_inbox 'v2', version => 2,
			indexlevel => 'medium', sub {
	my ($im) = @_;
	$im->add(eml_load 't/solve/0001-simple-mod.patch') or BAIL_OUT;
	$im->add($patch2) or BAIL_OUT;
};
my $md = "$tmpdir/md";
File::Path::mkpath([map { $md.$_ } (qw(/ /cur /new /tmp))]);
symlink(abs_path('t/solve/0001-simple-mod.patch'), "$md/cur/foo:2,") or
	xbail "symlink: $!";

my $v1_0_0_tag = 'cb7c42b1e15577ed2215356a2bf925aef59cdd8d';
my $v1_0_0_tag_short = substr($v1_0_0_tag, 0, 16);
my $expect = '69df7d565d49fbaaeb0a067910f03dc22cd52bd0';
my $non_existent = 'ee5e32211bf62ab6531bdf39b84b6920d0b6775a';

test_lei({tmpdir => "$tmpdir/blob"}, sub {
	lei_ok('blob', '--mail', $patch2_oid, '-I', $ibx->{inboxdir},
		\'--mail works for existing oid');
	is($lei_out, $patch2->as_string, 'blob matches');
	ok(!lei('blob', '--mail', '69df7d5', '-I', $ibx->{inboxdir}),
		"--mail won't run solver");
	like($lei_err, qr/\b69df7d5\b/, 'OID in error by git(1)');

	lei_ok('blob', '69df7d5', '-I', $ibx->{inboxdir});
	is(git_sha(1, \$lei_out)->hexdigest, $expect, 'blob contents output');
	my $prev = $lei_out;
	lei_ok(qw(blob --no-mail 69df7d5 -I), $ibx->{inboxdir});
	is($lei_out, $prev, '--no-mail works');
	ok(!lei(qw(blob -I), $ibx->{inboxdir}, $non_existent),
			'non-existent blob fails');
	my $abbrev = substr($non_existent, 0, 7);
	like($lei_err, qr/could not find $abbrev/, 'failed abbreviation noted');
	SKIP: {
		skip '/.git exists', 1 if -e '/.git';
		lei_ok(qw(-C / blob 69df7d5 -I), $ibx->{inboxdir},
			"--git-dir=$git_dir");
		is($lei_out, $prev, '--git-dir works');

		ok(!lei(qw(-C / blob --no-cwd 69df7d5 -I), $ibx->{inboxdir}),
			'--no-cwd works');
		like($lei_err, qr/no --git-dir to try/,
			'lack of --git-dir noted');

		ok(!lei(qw(-C / blob -I), $ibx->{inboxdir}, $non_existent),
			'non-existent blob fails');
		like($lei_err, qr/no --git-dir to try/,
			'lack of --git-dir noted');
	}

	# fallbacks
	lei_ok('blob', $v1_0_0_tag, '-I', $ibx->{inboxdir});
	lei_ok('blob', $v1_0_0_tag_short, '-I', $ibx->{inboxdir});
});

test_lei({tmpdir => "$tmpdir/rediff"}, sub {
	lei_ok(qw(rediff -q -U9 t/solve/0001-simple-mod.patch));
	like($lei_out, qr!^\Q+++\E b/TODO\n@@ -103,9 \+103,11 @@!sm,
		'got more context with -U9');

	my (undef, $re) = split(/\n\n/, $lei_out, 2);
	$re =~ s/^/> /sgm;
	substr($re, 0, 0, <<EOM);
From: me\@example.com
Subject: Re: awesome advice

WEB DESIGN EXPERT wrote:
EOM
	lei_ok([qw(rediff --full-index -U16 --drq)], undef,
		{ 0 => \$re, %$lei_opt });
	my $exp = <<'EOM';
From: me@example.com
Subject: Re: awesome advice

EOM
	like($lei_out, qr/\Q$exp\E/, '--drq preserved header');

	# n.b. --drq can requote the attribution line ("So-and-so wrote:"),
	# but it's probably not worth preventing...

	$exp = <<'EOM';
> ---
>  TODO | 2 ++
>  Ω    | 5 --
>  1 file changed, 2 insertions(+)
>
> diff --git a/TODO b/TODO
> index 605013e4904baabecd4a0a55997aebd8e8477a8f..69df7d565d49fbaaeb0a067910f03dc22cd52bd0 100644
> --- a/TODO
> +++ b/TODO
> @@ -96,16 +96,18 @@ all need to be considered for everything we introduce)
EOM
	$exp =~ s/^>$/> /sgm; # re-add trailing white space
	like($lei_out, qr/\Q$exp\E/, '--drq diffstat + context');

	lei_ok(qw(rediff -q --full-index -U9 t/solve/bare.patch));
	$exp = <<'EOM';
diff --git a/script/public-inbox-extindex b/script/public-inbox-extindex
old mode 100644
new mode 100755
index 15ac20eb871bf47697377e58a27db23102a38fca..771486c425b315bae70fd8a82d62ab0331e0a827
--- a/script/public-inbox-extindex
+++ b/script/public-inbox-extindex
@@ -1,13 +1,12 @@
 #!perl -w
EOM
	like($lei_out, qr/\Q$exp\E/,
		'preserve mode, regen header + context from -U0 patch');
	is($lei_err, '', 'no warnings from bare patch');
	my $e = { GIT_DIR => "$ENV{HOME}/.local/share/lei/store/ALL.git" };
	my @x = xqx([qw(git cat-file --batch-all-objects --batch-check)], $e);
	is_deeply(\@x, [], 'no objects stored') or diag explain(\@x);
});

test_lei({tmpdir => "$tmpdir/index-eml-only"}, sub {
	lei_ok(qw(index), $md);
	lei_ok(qw(blob 69df7d5)); # hits LeiSearch->smsg_eml -> lms->local_blob
});

my $git = PublicInbox::Git->new($git_dir);
$ibx->{-repo_objs} = [ $git ];
my $res;
my $solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
open my $log, '+>>', "$tmpdir/solve.log" or die "open: $!";
my $psgi_env = { 'psgi.errors' => \*STDERR, 'psgi.url_scheme' => 'http',
		'HTTP_HOST' => 'example.com' };
$solver->solve($psgi_env, $log, '69df7d5', {});
ok($res, 'solved a blob!');
my $wt_git = $res->[0];
is(ref($wt_git), 'PublicInbox::Git', 'got a git object for the blob');
is($res->[1], $expect, 'resolved blob to unabbreviated identifier');
is($res->[2], 'blob', 'type specified');
is($res->[3], 4405, 'size returned');

is(ref($wt_git->cat_file($res->[1])), 'SCALAR', 'wt cat-file works');
is_deeply([$expect, 'blob', 4405],
	  [$wt_git->check($res->[1])], 'wt check works');

my $oid = $expect;
for my $i (1..2) {
	my $more;
	my $s = PublicInbox::SolverGit->new($ibx, sub { $more = $_[0] });
	$s->solve($psgi_env, $log, $oid, {});
	is($more->[1], $expect, 'resolved blob to long OID '.$i);
	chop($oid);
}

$solver = undef;
$res = undef;
my $wt_git_dir = $wt_git->{git_dir};
$wt_git = undef;
ok(!-d $wt_git_dir, 'no references to WT held');

$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, '0'x40, {});
is($res, undef, 'no error on z40');

my $git_v2_20_1_tag = '7a95a1cd084cb665c5c2586a415e42df0213af74';
$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, $git_v2_20_1_tag, {});
is($res, undef, 'no error on a tag not in our repo');

$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, '0a92431', {});
ok($res, 'resolved without hints');

my $hints = {
	oid_a => '3435775',
	path_a => 'HACKING',
	path_b => 'CONTRIBUTING'
};
$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, '0a92431', $hints);
my $hinted = $res;
# don't compare ::Git objects:
shift @$res; shift @$hinted;
is_deeply($res, $hinted, 'hints work (or did not hurt :P');

my @psgi = qw(HTTP::Request::Common Plack::Test URI::Escape Plack::Builder);
SKIP: {
	require_mods(@psgi, 7 + scalar(@psgi));
	use_ok($_) for @psgi;
	my $binfoo = "$ibx->{inboxdir}/binfoo.git";
	my $l = "$ibx->{inboxdir}/inbox.lock";
	-f $l or BAIL_OUT "BUG: $l missing: $!";
	require_ok 'PublicInbox::ViewVCS';
	my $big_size = do {
		no warnings 'once';
		$PublicInbox::ViewVCS::MAX_SIZE + 1;
	};
	my %bin = (big => $big_size, small => 1);
	my %oid; # (small|big) => OID
	my $lk = bless { lock_path => $l }, 'PublicInbox::Lock';
	my $acq = $lk->lock_for_scope;
	my $stamp = "$binfoo/stamp";
	if (open my $fh, '<', $stamp) {
		%oid = map { chomp; split(/=/, $_) } (<$fh>);
	} else {
		PublicInbox::Import::init_bare($binfoo);
		my $cmd = [ qw(git hash-object -w --stdin) ];
		my $env = { GIT_DIR => $binfoo };
		open my $fh, '>', "$stamp.$$" or BAIL_OUT;
		while (my ($label, $size) = each %bin) {
			pipe(my ($rin, $win)) or BAIL_OUT;
			my $rout = popen_rd($cmd , $env, { 0 => $rin });
			$rin = undef;
			print { $win } ("\0" x $size) or BAIL_OUT;
			close $win or BAIL_OUT;
			chomp(my $x = <$rout>);
			close $rout or BAIL_OUT "$?";
			print $fh "$label=$x\n" or BAIL_OUT;
			$oid{$label} = $x;
		}
		close $fh or BAIL_OUT;
		rename("$stamp.$$", $stamp) or BAIL_OUT;
	}
	undef $acq;
	# ensure the PSGI frontend (ViewVCS) works:
	my $name = $ibx->{name};
	my $cfgpfx = "publicinbox.$name";
	my $cfgpath = "$tmpdir/httpd-config";
	open my $cfgfh, '>', $cfgpath or die;
	print $cfgfh <<EOF or die;
[publicinbox "$name"]
	address = $ibx->{-primary_address}
	inboxdir = $ibx->{inboxdir}
	coderepo = public-inbox
	coderepo = binfoo
	url = http://example.com/$name
[coderepo "public-inbox"]
	dir = $git_dir
	cgiturl = http://example.com/public-inbox
[coderepo "binfoo"]
	dir = $binfoo
	cgiturl = http://example.com/binfoo
EOF
	close $cfgfh or die;
	my $cfg = PublicInbox::Config->new($cfgpath);
	my $www = PublicInbox::WWW->new($cfg);
	my $client = sub {
		my ($cb) = @_;
		my $mid = '20190401081523.16213-1-BOFH@YHBT.net';
		my @warn;
		my $res = do {
			local $SIG{__WARN__} = sub { push @warn, @_ };
			$cb->(GET("/$name/$mid/"));
		};
		is_deeply(\@warn, [], 'no warnings from rendering diff');
		like($res->content, qr!>&#937;</a>!, 'omega escaped');

		$res = $cb->(GET("/$name/3435775/s/"));
		is($res->code, 200, 'success with existing blob');

		$res = $cb->(GET("/$name/".('0'x40).'/s/'));
		is($res->code, 404, 'failure with null OID');

		$res = $cb->(GET("/$name/$non_existent/s/"));
		is($res->code, 404, 'failure with null OID');

		$res = $cb->(GET("/$name/$v1_0_0_tag/s/"));
		is($res->code, 200, 'shows commit (unabbreviated)');
		$res = $cb->(GET("/$name/$v1_0_0_tag_short/s/"));
		is($res->code, 200, 'shows commit (abbreviated)');
		while (my ($label, $size) = each %bin) {
			$res = $cb->(GET("/$name/$oid{$label}/s/"));
			is($res->code, 200, "$label binary file");
			ok(index($res->content,
				"blob $oid{$label} $size bytes") >= 0,
				"showed $label binary blob size");
			$res = $cb->(GET("/$name/$oid{$label}/s/raw"));
			is($res->code, 200, "$label raw binary download");
			is($res->content, "\0" x $size,
				"$label content matches");
		}
		my $utf8 = 'e022d3377fd2c50fd9931bf96394728958a90bf3';
		$res = $cb->(GET("/$name/$utf8/s/"));
		is($res->code, 200, 'shows commit w/ utf8.eml');
		like($res->content, qr/El&#233;anor/,
				'UTF-8 commit shown properly');
	};
	test_psgi(sub { $www->call(@_) }, $client);
	SKIP: {
		require_mods(qw(Plack::Test::ExternalServer), 7);
		my $env = { PI_CONFIG => $cfgpath };
		my $sock = tcp_server() or die;
		my ($out, $err) = map { "$tmpdir/std$_.log" } qw(out err);
		my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
		my $td = start_script($cmd, $env, { 3 => $sock });
		my ($h, $p) = tcp_host_port($sock);
		my $url = "http://$h:$p";
		local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = $url;
		Plack::Test::ExternalServer::test_psgi(client => $client);
		require_cmd('curl', 1) or skip 'no curl', 1;

		mkdir "$tmpdir/ext" // xbail "mkdir $!";
		test_lei({tmpdir => "$tmpdir/ext"}, sub {
			my $rurl = "$url/$name";
			lei_ok(qw(blob --no-mail 69df7d5 -I), $rurl);
			is(git_sha(1, \$lei_out)->hexdigest, $expect,
				'blob contents output');
			ok(!lei(qw(blob -I), $rurl, $non_existent),
					'non-existent blob fails');
		});
	}
}

done_testing();
