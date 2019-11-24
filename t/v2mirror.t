# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
require './t/common.perl';
require_git(2.6);

# Integration tests for HTTP cloning + mirroring
foreach my $mod (qw(Plack::Util Plack::Builder
			HTTP::Date HTTP::Status Search::Xapian DBD::SQLite)) {
	eval "require $mod";
	plan skip_all => "$mod missing for v2mirror.t" if $@;
}
use File::Temp qw/tempdir/;
use IO::Socket;
use POSIX qw(dup2);
use_ok 'PublicInbox::V2Writable';
use PublicInbox::InboxWritable;
use PublicInbox::MIME;
use PublicInbox::Config;
# FIXME: too much setup
my $tmpdir = tempdir('pi-v2mirror-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $pi_config = "$tmpdir/config";
{
	open my $fh, '>', $pi_config or die "open($pi_config): $!";
	print $fh <<"" or die "print $pi_config: $!";
[publicinbox "v2"]
	inboxdir = $tmpdir/in
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
$ibx->cleanup;

my $sock = tcp_server();
ok($sock, 'sock created');
my $cmd = [ '-httpd', '-W0', "--stdout=$tmpdir/out", "--stderr=$tmpdir/err" ];
my $td = start_script($cmd, undef, { 3 => $sock });
my ($host, $port) = ($sock->sockhost, $sock->sockport);
$sock = undef;

my @cmd;
foreach my $i (0..$epoch_max) {
	my $sfx = $i == 0 ? '.git' : '';
	@cmd = (qw(git clone --mirror -q),
		"http://$host:$port/v2/$i$sfx",
		"$tmpdir/m/git/$i.git");

	is(system(@cmd), 0, "cloned $i.git");
	ok(-d "$tmpdir/m/git/$i.git", "mirror $i OK");
}

@cmd = ("-init", '-V2', 'm', "$tmpdir/m", 'http://example.com/m',
	'alt@example.com');
ok(run_script(\@cmd), 'initialized public-inbox -V2');

ok(run_script(['-index', "$tmpdir/m"]), 'indexed');

my $mibx = { inboxdir => "$tmpdir/m", address => 'alt@example.com' };
$mibx = PublicInbox::Inbox->new($mibx);
is_deeply([$mibx->mm->minmax], [$ibx->mm->minmax], 'index synched minmax');

$v2w->{rotate_bytes} = $old_rotate_bytes;
for my $i (10..15) {
	$mime->header_set('Message-ID', "<$i\@example.com>");
	$mime->header_set('Subject', "subject = $i");
	ok($v2w->add($mime), "add msg $i OK");
}
$v2w->done;
$ibx->cleanup;

sub fetch_each_epoch {
	foreach my $i (0..$epoch_max) {
		my $dir = "$tmpdir/m/git/$i.git";
		is(system('git', "--git-dir=$dir", 'fetch', '-q'), 0,
			'fetch successful');
	}
}

fetch_each_epoch();

my $mset = $mibx->search->reopen->query('m:15@example.com', {mset => 1});
is(scalar($mset->items), 0, 'new message not found in mirror, yet');
ok(run_script(["-index", "$tmpdir/m"]), 'index updated');
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

$v2w->done;

my $msgs = $mibx->search->{over_ro}->get_thread('10@example.com');
my $to_purge = $msgs->[0]->{blob};
like($to_purge, qr/\A[a-f0-9]{40,}\z/, 'read blob to be purged');
$mset = $ibx->search->reopen->query('m:10@example.com', {mset => 1});
is(scalar($mset->items), 0, 'purged message gone from origin');

fetch_each_epoch();
{
	$ibx->cleanup;
	PublicInbox::InboxWritable::cleanup($mibx);
	$v2w->done;
	my $cmd = [ '-index', '--prune', "$tmpdir/m" ];
	my ($out, $err) = ('', '');
	my $opt = { 1 => \$out, 2 => \$err };
	ok(run_script($cmd, undef, $opt), '-index --prune');
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

# deletes happen in a different fetch window
{
	$mset = $mibx->search->reopen->query('m:1@example.com', {mset => 1});
	is(scalar($mset->items), 1, '1@example.com visible in mirror');
	$mime->header_set('Message-ID', '<1@example.com>');
	$mime->header_set('Subject', 'subject = 1');
	ok($v2w->remove($mime), 'removed <1@example.com> from source');
	$v2w->done;
	$ibx->cleanup;
	fetch_each_epoch();
	PublicInbox::InboxWritable::cleanup($mibx);

	my $cmd = [ "-index", "$tmpdir/m" ];
	my ($out, $err) = ('', '');
	my $opt = { 1 => \$out, 2 => \$err };
	ok(run_script($cmd, undef, $opt), 'index ran');
	is($err, '', 'no errors reported by index');
	$mset = $mibx->search->reopen->query('m:1@example.com', {mset => 1});
	is(scalar($mset->items), 0, '1@example.com no longer visible in mirror');
}

ok($td->kill, 'killed httpd');
$td->join;

done_testing();

1;
