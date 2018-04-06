# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;

# Integration tests for HTTP cloning + mirroring
foreach my $mod (qw(Plack::Util Plack::Builder Danga::Socket
			HTTP::Date HTTP::Status Search::Xapian DBD::SQLite)) {
	eval "require $mod";
	plan skip_all => "$mod missing for v2mirror.t" if $@;
}
use File::Temp qw/tempdir/;
use IO::Socket;
use POSIX qw(dup2);
use_ok 'PublicInbox::V2Writable';
use PublicInbox::MIME;
use PublicInbox::Config;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
# FIXME: too much setup
my $tmpdir = tempdir('pi-v2mirror-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $script = 'blib/script/public-inbox';
my $pi_config = "$tmpdir/config";
{
	open my $fh, '>', $pi_config or die "open($pi_config): $!";
	print $fh <<"" or die "print $pi_config: $!";
[publicinbox "v2"]
	mainrepo = $tmpdir/in
	address = test\@example.com

	close $fh or die "close($pi_config): $!";
}
local $ENV{PI_CONFIG} = $pi_config;

my $cfg = PublicInbox::Config->new($pi_config);
my $ibx = $cfg->lookup('test@example.com');
ok($ibx, 'inbox found');
$ibx->{version} = 2;
my $v2w = PublicInbox::V2Writable->new($ibx, 1);
ok $v2w, 'v2w loaded';
$v2w->{parallel} = 0;
my $mime = PublicInbox::MIME->new(<<'');
From: Me <me@example.com>
To: You <you@example.com>
Subject: a
Date: Thu, 01 Jan 1970 00:00:00 +0000

for my $i (1..9) {
	$mime->header_set('Message-ID', "<$i\@example.com>");
	$mime->header_set('Subject', "subject = $i");
	ok($v2w->add($mime), "add msg $i OK");
}
$v2w->barrier;

my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Listen => 1024,
);
my ($sock, $pid);
END { kill 'TERM', $pid if defined $pid };

$! = 0;
$sock = IO::Socket::INET->new(%opts);
ok($sock, 'sock created');
my $fl = fcntl($sock, F_GETFD, 0);
$pid = fork;
if ($pid == 0) {
	# pretend to be systemd
	fcntl($sock, F_SETFD, $fl &= ~FD_CLOEXEC);
	dup2(fileno($sock), 3) or die "dup2 failed: $!\n";
	$ENV{LISTEN_PID} = $$;
	$ENV{LISTEN_FDS} = 1;
	exec "$script-httpd", "--stdout=$tmpdir/out", "--stderr=$tmpdir/err";
	die "FAIL: $!\n";
}
ok(defined $pid, 'forked httpd process successfully');
my ($host, $port) = ($sock->sockhost, $sock->sockport);
$sock = undef;

my @cmd = (qw(git clone --mirror -q), "http://$host:$port/v2/0",
	"$tmpdir/m/git/0.git");

is(system(@cmd), 0, 'cloned OK');
ok(-d "$tmpdir/m/git/0.git", 'mirror OK');;

@cmd = ("$script-init", '-V2', 'm', "$tmpdir/m", 'http://example.com/m',
	'alt@example.com');
is(system(@cmd), 0, 'initialized public-inbox -V2');
is(system("$script-index", "$tmpdir/m"), 0, 'indexed');

my $mibx = { mainrepo => "$tmpdir/m", address => 'alt@example.com' };
$mibx = PublicInbox::Inbox->new($mibx);
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'index synched minmax');

for my $i (10..15) {
	$mime->header_set('Message-ID', "<$i\@example.com>");
	$mime->header_set('Subject', "subject = $i");
	ok($v2w->add($mime), "add msg $i OK");
}
$v2w->barrier;
is(system('git', "--git-dir=$tmpdir/m/git/0.git", 'fetch', '-q'), 0,
	'fetch successful');

my $mset = $mibx->search->reopen->query('m:15@example.com', {mset => 1});
is(scalar($mset->items), 0, 'new message not found in mirror, yet');
is(system("$script-index", "$tmpdir/m"), 0, 'index updated');
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'index synched minmax');
$mset = $mibx->search->reopen->query('m:15@example.com', {mset => 1});
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

$v2w->barrier;

my $msgs = $mibx->search->{over_ro}->get_thread('10@example.com');
my $to_purge = $msgs->[0]->{blob};
like($to_purge, qr/\A[a-f0-9]{40,}\z/, 'read blob to be purged');
$mset = $ibx->search->reopen->query('m:10@example.com', {mset => 1});
is(scalar($mset->items), 0, 'purged message gone from origin');

is(system('git', "--git-dir=$tmpdir/m/git/0.git", 'fetch', '-q'), 0,
	'fetch successful');
{
	open my $err, '+>', "$tmpdir/index-err" or die "open: $!";
	my $ipid = fork;
	if ($ipid == 0) {
		dup2(fileno($err), 2) or die "dup2 failed: $!";
		exec("$script-index", '--prune', "$tmpdir/m");
		die "exec fail: $!";
	}
	ok($ipid, 'running index..');
	is(waitpid($ipid, 0), $ipid, 'index --prune done');
	is($?, 0, 'no error from index');
	ok(seek($err, 0, 0), 'rewound stderr');
	$err = eval { local $/; <$err> };
	like($err, qr/discontiguous range/, 'warned about discontiguous range');
	unlike($err, qr/fatal/, 'no scary fatal error shown');
}

$mset = $mibx->search->reopen->query('m:10@example.com', {mset => 1});
is(scalar($mset->items), 0, 'purged message not found in mirror');
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'minmax still synced');
for my $i ((1..9),(11..15)) {
	$mset = $mibx->search->query("m:$i\@example.com", {mset => 1});
	is(scalar($mset->items), 1, "$i\@example.com remains visible");
}
is($mibx->git->check($to_purge), undef, 'unindex+prune successful in mirror');

{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	$v2w->index_sync;
	is_deeply(\@warn, [], 'no warnings from index_sync after purge');
}

$v2w->done;
ok(kill('TERM', $pid), 'killed httpd');
$pid = undef;
waitpid(-1, 0);

done_testing();

1;
