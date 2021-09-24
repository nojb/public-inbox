# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use File::Path qw(remove_tree make_path);
use Cwd qw(abs_path);
use PublicInbox::Spawn qw(which);
require_git(2.6);
require_cmd('curl');
local $ENV{HOME} = abs_path('t');
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

# Integration tests for HTTP cloning + mirroring
require_mods(qw(Plack::Util Plack::Builder
		HTTP::Date HTTP::Status Search::Xapian DBD::SQLite));
use_ok 'PublicInbox::V2Writable';
use PublicInbox::InboxWritable;
use PublicInbox::Eml;
use PublicInbox::Config;
# FIXME: too much setup
my ($tmpdir, $for_destroy) = tmpdir();
my $pi_config = "$tmpdir/config";
{
	open my $fh, '>', $pi_config or die "open($pi_config): $!";
	print $fh <<"" or die "print $pi_config: $!";
[publicinbox "v2"]
; using "mainrepo" rather than "inboxdir" for v1.1.0-pre1 WWW compat below
	mainrepo = $tmpdir/in
	address = test\@example.com

	close $fh or die "close($pi_config): $!";
}
local $ENV{PI_CONFIG} = $pi_config;

my $cfg = PublicInbox::Config->new($pi_config);
my $ibx = $cfg->lookup('test@example.com');
ok($ibx, 'inbox found');
$ibx->{version} = 2;
$ibx->{-no_fsync} = 1;
my $v2w = PublicInbox::V2Writable->new($ibx, 1);
ok $v2w, 'v2w loaded';
$v2w->{parallel} = 0;
my $mime = PublicInbox::Eml->new(<<'');
From: Me <me@example.com>
To: You <you@example.com>
Subject: a
Date: Thu, 01 Jan 1970 00:00:00 +0000

my $old_rotate_bytes = $v2w->{rotate_bytes};
$v2w->{rotate_bytes} = 500; # force rotating
for my $i (1..9) {
	$mime->header_set('Message-ID', "<$i\@example.com>");
	$mime->header_set('Subject', "subject = $i");
	ok($v2w->add($mime), "add msg $i OK");
}

my $epoch_max = $v2w->{epoch_max};
ok($epoch_max > 0, "multiple epochs");
$v2w->done;
{
	my $smsg = $ibx->over->get_art(1);
	like($smsg->{lines}, qr/\A[0-9]+\z/, 'lines is a digit');
	like($smsg->{bytes}, qr/\A[0-9]+\z/, 'bytes is a digit');
}
$ibx->cleanup;

local $ENV{TEST_IPV4_ONLY} = 1; # plackup (below) doesn't do IPv6
my $rdr = { 3 => tcp_server() };
my @cmd = ('-httpd', '-W0', "--stdout=$tmpdir/out", "--stderr=$tmpdir/err");
my $td = start_script(\@cmd, undef, $rdr);
my ($host, $port) = tcp_host_port(delete $rdr->{3});

@cmd = (qw(-clone -q), "http://$host:$port/v2/", "$tmpdir/m");
run_script(\@cmd) or xbail '-clone';

for my $i (0..$epoch_max) {
	ok(-d "$tmpdir/m/git/$i.git", "epoch $i cloned");
}

@cmd = ("-init", '-j1', '-V2', 'm', "$tmpdir/m", 'http://example.com/m',
	'alt@example.com');
ok(run_script(\@cmd), 'initialized public-inbox -V2');
my @shards = glob("$tmpdir/m/xap*/?");
is(scalar(@shards), 1, 'got a single shard on init');

ok(run_script([qw(-index -j0), "$tmpdir/m"]), 'indexed');

my $mibx = { inboxdir => "$tmpdir/m", address => 'alt@example.com' };
$mibx = PublicInbox::Inbox->new($mibx);
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'index synched minmax');

for my $i (10..15) {
	$mime->header_set('Message-ID', "<$i\@example.com>");
	$mime->header_set('Subject', "subject = $i");
	ok($v2w->add($mime), "add msg $i OK");
}
$v2w->done;
$ibx->cleanup;

my @new_epochs;
my $fetch_each_epoch = sub {
	my %before = map { $_ => 1 } glob("$tmpdir/m/git/*");
	run_script([qw(-fetch --exit-code -q)], undef, {-C => "$tmpdir/m"}) or
		xbail '-fetch fail';
	is($?, 0, '--exit-code 0 after fetch updated');
	my @after = grep { !$before{$_} } glob("$tmpdir/m/git/*");
	push @new_epochs, @after;
};

$fetch_each_epoch->();

my $mset = $mibx->search->reopen->mset('m:15@example.com');
is(scalar($mset->items), 0, 'new message not found in mirror, yet');
ok(run_script([qw(-index -j0), "$tmpdir/m"]), 'index updated');
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'index synched minmax');
$mset = $mibx->search->reopen->mset('m:15@example.com');
is(scalar($mset->items), 1, 'found message in mirror');

# purge:
$mime->header_set('Message-ID', '<10@example.com>');
$mime->header_set('Subject', 'subject = 10');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	ok($v2w->purge($mime), 'purge a message');
	my $warn = join('', @warn);
	like($warn, qr/purge rewriting/);
	my @subj = ($warn =~ m/^# subject .*$/mg);
	is_deeply(\@subj, ["# subject = 10"], "only rewrote one");
}

$v2w->done;

my $msgs = $mibx->over->get_thread('10@example.com');
my $to_purge = $msgs->[0]->{blob};
like($to_purge, qr/\A[a-f0-9]{40,}\z/, 'read blob to be purged');
$mset = $ibx->search->reopen->mset('m:10@example.com');
is(scalar($mset->items), 0, 'purged message gone from origin');

$fetch_each_epoch->();
{
	$ibx->cleanup;
	PublicInbox::InboxWritable::cleanup($mibx);
	$v2w->done;
	my $cmd = [ qw(-index --prune -j0), "$tmpdir/m" ];
	my ($out, $err) = ('', '');
	my $opt = { 1 => \$out, 2 => \$err };
	ok(run_script($cmd, undef, $opt), '-index --prune');
	like($err, qr/discontiguous range/, 'warned about discontiguous range');
	unlike($err, qr/fatal/, 'no scary fatal error shown');
}

$mset = $mibx->search->reopen->mset('m:10@example.com');
is(scalar($mset->items), 0, 'purged message not found in mirror');
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'minmax still synced');
for my $i ((1..9),(11..15)) {
	$mset = $mibx->search->mset("m:$i\@example.com");
	is(scalar($mset->items), 1, "$i\@example.com remains visible");
}
is($mibx->git->check($to_purge), undef, 'unindex+prune successful in mirror');

{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	$v2w->index_sync;
	is_deeply(\@warn, [], 'no warnings from index_sync after purge');
}

# deletes happen in a different fetch window
{
	$mset = $mibx->search->reopen->mset('m:1@example.com');
	is(scalar($mset->items), 1, '1@example.com visible in mirror');
	$mime->header_set('Message-ID', '<1@example.com>');
	$mime->header_set('Subject', 'subject = 1');
	ok($v2w->remove($mime), 'removed <1@example.com> from source');
	$v2w->done;
	$ibx->cleanup;
	$fetch_each_epoch->();
	PublicInbox::InboxWritable::cleanup($mibx);

	my $cmd = [ qw(-index -j0), "$tmpdir/m" ];
	my ($out, $err) = ('', '');
	my $opt = { 1 => \$out, 2 => \$err };
	ok(run_script($cmd, undef, $opt), 'index ran');
	is($err, '', 'no errors reported by index');
	$mset = $mibx->search->reopen->mset('m:1@example.com');
	is(scalar($mset->items), 0, '1@example.com no longer visible in mirror');
}

if ('sequential-shard') {
	$mset = $mibx->search->mset('m:15@example.com');
	is(scalar($mset->items), 1, 'large message not indexed');
	remove_tree(glob("$tmpdir/m/xap*"), glob("$tmpdir/m/msgmap.*"));
	my $cmd = [ qw(-index -j9 --sequential-shard), "$tmpdir/m" ];
	ok(run_script($cmd), '--sequential-shard works');
	my @shards = glob("$tmpdir/m/xap*/?");
	is(scalar(@shards), 8, 'got expected shard count');
	PublicInbox::InboxWritable::cleanup($mibx);
	$mset = $mibx->search->mset('m:15@example.com');
	is(scalar($mset->items), 1, 'search works after --sequential-shard');
}

if ('max size') {
	$mime->header_set('Message-ID', '<2big@a>');
	my $max = '2k';
	$mime->body_str_set("z\n" x 1024);
	ok($v2w->add($mime), "add big message");
	$v2w->done;
	$ibx->cleanup;
	$fetch_each_epoch->();
	PublicInbox::InboxWritable::cleanup($mibx);
	my $cmd = [qw(-index -j0), "$tmpdir/m", "--max-size=$max" ];
	my $opt = { 2 => \(my $err) };
	ok(run_script($cmd, undef, $opt), 'indexed with --max-size');
	like($err, qr/skipping [a-f0-9]{40,}/, 'warned about skipping message');
	$mset = $mibx->search->reopen->mset('m:2big@a');
	is(scalar($mset->items), 0, 'large message not indexed');

	{
		open my $fh, '>>', $pi_config or die;
		print $fh <<EOF or die;
[publicinbox]
	indexMaxSize = 2k
EOF
		close $fh or die;
	}
	$cmd = [ qw(-index -j0 --reindex), "$tmpdir/m" ];
	ok(run_script($cmd, undef, $opt), 'reindexed w/ indexMaxSize in file');
	like($err, qr/skipping [a-f0-9]{40,}/, 'warned about skipping message');
	$mset = $mibx->search->reopen->mset('m:2big@a');
	is(scalar($mset->items), 0, 'large message not re-indexed');
}
ok(scalar(@new_epochs), 'new epochs were created and fetched');
for my $d (@new_epochs) {
	is(xqx(['git', "--git-dir=$d", 'config', qw(include.path)]),
		"../../all.git/config\n",
		'include.path set');
}

if ('test read-only epoch dirs') {
	my @git = ('git', "--git-dir=$new_epochs[0]");
	my $get_objs = [@git,
		qw(cat-file --buffer --batch-check --batch-all-objects)];
	my $before = [sort xqx($get_objs)];

	remove_tree(map { "$new_epochs[0]/$_" } qw(objects refs/heads));
	chmod(0555, $new_epochs[0]) or xbail "chmod: $!";

	# force a refetch
	unlink("$tmpdir/m/manifest.js.gz") or xbail "unlink: $!";

	run_script([qw(-fetch -q)], undef, {-C => "$tmpdir/m"}) or
		xbail '-fetch failed';

	ok(!-d "$new_epochs[0]/objects", 'no objects after fetch to R/O dir');

	chmod(0755, $new_epochs[0]) or xbail "chmod: $!";
	mkdir("$new_epochs[0]/objects") or xbail "mkdir: $!";
	mkdir("$new_epochs[0]/refs/heads") or xbail "mkdir: $!";

	my $err = '';
	run_script([qw(-fetch -q)], undef, {-C => "$tmpdir/m", 2 => \$err}) or
		xbail '-fetch failed '.$err;
	is_deeply([ sort xqx($get_objs) ], $before,
		'fetch restored objects once GIT_DIR became writable');
}

{
	my $dst = "$tmpdir/partial";
	run_script([qw(-clone -q --epoch=~0), "http://$host:$port/v2/", $dst]);
	is($?, 0, 'no error from partial clone');
	my @g = glob("$dst/git/*.git");
	my @w = grep { -w $_ } @g;
	my @r = grep { ! -w $_ } @g;
	is(scalar(@w), 1, 'one writable directory');
	my ($w) = ($w[0] =~ m!/([0-9]+)\.git\z!);
	is((grep {
		m!/([0-9]+)\.git\z! or xbail "no digit in $_";
		$w > ($1 + 0)
	} @r), scalar(@r), 'writable epoch # exceeds read-only ones');
	run_script([qw(-fetch -q)], undef, { -C => $dst });
	is($?, 0, 'no error from partial fetch');
	remove_tree($dst);

	run_script([qw(-clone -q --epoch=~1..),
			"http://$host:$port/v2/", $dst]);
	my @g2 = glob("$dst/git/*.git") ;
	is_deeply(\@g2, \@g, 'cloned again');
	is(scalar(grep { -w $_ } @g2), scalar(@w) + 1,
		'got one more cloned epoch');

	# make 0.git writable and fetch into it, relies on culled manifest
	chmod(0755, $g2[0]) or xbail "chmod: $!";
	my @before = glob("$g2[0]/objects/*/*");
	run_script([qw(-fetch -q)], undef, { -C => $dst });
	is($?, 0, 'no error from partial fetch');
	my @after = glob("$g2[0]/objects/*/*");
	ok(scalar(@before) < scalar(@after), 'fetched after chmod 0755 0.git');

	# ensure culled manifest is maintained after fetch
	gunzip("$dst/manifest.js.gz" => \(my $m), MultiStream => 1) or
		xbail "gunzip: $GunzipError";
	$m = PublicInbox::Config->json->decode($m);
	for my $k (keys %$m) { # /$name/git/$N.git
		my ($nr) = ($k =~ m!/git/([0-9]+)\.git\z!);
		ok(-w "$dst/git/$nr.git", "writable $nr.git in manifest");
	}
	for my $ro (grep { !-w $_ } @g2) {
		my ($nr) = ($ro =~ m!/git/([0-9]+)\.git\z!);
		is(grep(m!/git/$nr\.git\z!, keys %$m), 0,
			"read-only $nr.git not in manifest")
			or xbail([sort keys %$m]);
	}
}

my $err = '';
my $v110 = xqx([qw(git rev-parse v1.1.0-pre1)], undef, { 2 => \$err });
SKIP: {
	skip("no detected public-inbox GIT_DIR ($err)", 1) if $?;
	# using plackup to test old PublicInbox::WWW since -httpd from
	# back then relied on some packages we no longer depend on
	my $plackup = which('plackup') or skip('no plackup in path', 1);
	require PublicInbox::Lock;
	chomp $v110;
	my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
	my $wt = "t/data-gen/$base.pre-manifest";
	my $lk = bless { lock_path => __FILE__ }, 'PublicInbox::Lock';
	$lk->lock_acquire;
	my $psgi = "$wt/app.psgi";
	if (!-f $psgi) { # checkout a pre-manifest.js.gz version
		my $t = File::Temp->new(TEMPLATE => 'g-XXXX', TMPDIR => 1);
		my $env = { GIT_INDEX_FILE => $t->filename };
		xsys([qw(git read-tree), $v110], $env) and xbail 'read-tree';
		xsys([qw(git checkout-index -a), "--prefix=$wt/"], $env)
			and xbail 'checkout-index';
		my $f = "$wt/app.psgi.tmp.$$";
		open my $fh, '>', $f or xbail $!;
		print $fh <<'EOM' or xbail $!;
use Plack::Builder;
use PublicInbox::WWW;
my $www = PublicInbox::WWW->new;
builder { enable 'Head'; sub { $www->call(@_) } }
EOM
		close $fh or xbail $!;
		rename($f, $psgi) or xbail $!;
	}
	$lk->lock_release;

	$rdr->{run_mode} = 0;
	$rdr->{-C} = $wt;
	my $cmd = [$plackup, qw(-Enone -Ilib), "--host=$host", "--port=$port"];
	$td->join('TERM');
	open $rdr->{2}, '>>', "$tmpdir/plackup.err.log" or xbail "open: $!";
	open $rdr->{1}, '>>&', $rdr->{2} or xbail "open: $!";
	$td = start_script($cmd, { PERL5LIB => 'lib' }, $rdr);
	# wait for plackup socket()+bind()+listen()
	my %opt = ( Proto => 'tcp', Type => Socket::SOCK_STREAM(),
		PeerAddr => "$host:$port" );
	for (0..50) {
		tick();
		last if IO::Socket::INET->new(%opt);
	}
	my $dst = "$tmpdir/scrape";
	@cmd = (qw(-clone -q), "http://$host:$port/v2", $dst);
	run_script(\@cmd, undef, { 2 => \(my $err = '') });
	is($?, 0, 'scraping clone on old PublicInbox::WWW')
		or diag $err;
	my @g_all = glob("$dst/git/*.git");
	ok(scalar(@g_all) > 1, 'cloned multiple epochs');

	remove_tree($dst);
	@cmd = (qw(-clone -q --epoch=~0), "http://$host:$port/v2", $dst);
	run_script(\@cmd, undef, { 2 => \($err = '') });
	is($?, 0, 'partial scraping clone on old PublicInbox::WWW');
	my @g_last = grep { -w $_ } glob("$dst/git/*.git");
	is_deeply(\@g_last, [ $g_all[-1] ], 'partial clone of ~0 worked');

	chmod(0755, $g_all[0]) or xbail "chmod $!";
	my @before = glob("$g_all[0]/objects/*/*");
	run_script([qw(-fetch -v)], undef, { -C => $dst, 2 => \($err = '') });
	is($?, 0, 'scraping fetch on old PublicInbox::WWW') or diag $err;
	my @after = glob("$g_all[0]/objects/*/*");
	ok(scalar(@before) < scalar(@after),
		'fetched 0.git after enabling write-bit');

	$td->join('TERM');
}

done_testing;
