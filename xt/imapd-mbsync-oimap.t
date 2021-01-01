#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# ensure mbsync and offlineimap compatibility
use strict;
use Test::More;
use File::Path qw(mkpath);
use PublicInbox::TestCommon;
use PublicInbox::Spawn qw(which spawn);
require_mods(qw(DBD::SQLite Email::Address::XS||Mail::Address));
my $inboxdir = $ENV{GIANT_INBOX_DIR};
(defined($inboxdir) && -d $inboxdir) or
	plan skip_all => "GIANT_INBOX_DIR not defined for $0";
plan skip_all => "bad characters in $inboxdir" if $inboxdir =~ m![^\w\.\-/]!;
my ($tmpdir, $for_destroy) = tmpdir();
my $cfg = "$tmpdir/cfg";
my $newsgroup = 'inbox.test';
my $mailbox = "$newsgroup.0";
{
	open my $fh, '>', $cfg or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT "print: $!";
[publicinbox "test"]
	newsgroup = $newsgroup
	address = oimap\@example.com
	inboxdir = $inboxdir
EOF
	close $fh or BAIL_OUT "close: $!";
}
my ($out, $err) = ("$tmpdir/stdout.log", "$tmpdir/stderr.log");
my $sock = tcp_server();
my $cmd = [ '-imapd', '-W0', "--stdout=$out", "--stderr=$err" ];
my $env = { PI_CONFIG => $cfg };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT "-imapd: $?";
{
	my $c = tcp_connect($sock);
	like(readline($c), qr/CAPABILITY /, 'got greeting');
}
my ($host, $port) = ($sock->sockhost, $sock->sockport);
my %pids;

SKIP: {
	mkpath([map { "$tmpdir/oimapdir/$_" } qw(cur new tmp)]);
	my $oimap = which('offlineimap') or skip 'no offlineimap(1)', 1;
	open my $fh, '>', "$tmpdir/.offlineimaprc" or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT "print: $!";
[general]
accounts = test
socktimeout = 10
fsync = false

[Account test]
localrepository = l.test
remoterepository = r.test

[Repository l.test]
type = Maildir
localfolders = ~/oimapdir

[Repository r.test]
type = IMAP
ssl = no
remotehost = $host
remoteport = $port
remoteuser = anonymous
remotepass = Hunter2

# python-imaplib2 times out on select/poll when compression is enabled
# <https://bugs.debian.org/961713>
usecompression = no
EOF
	close $fh or BAIL_OUT "close: $!";
	my $cmd = [ $oimap, qw(-o -q -u quiet) ];
	my $pid = spawn($cmd, { HOME => $tmpdir }, { 1 => 2 });
	$pids{$pid} = $cmd;
}

SKIP: {
	mkpath([map { "$tmpdir/mbsyncdir/test/$_" } qw(cur new tmp)]);
	my $mbsync = which('mbsync') or skip 'no mbsync(1)', 1;
	open my $fh, '>', "$tmpdir/.mbsyncrc" or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT "print: $!";
Create Slave
SyncState *
Remove None
FSync no

MaildirStore local
Path ~/mbsyncdir/
Inbox ~/mbsyncdir/test
SubFolders verbatim

IMAPStore remote
Host $host
Port $port
User anonymous
Pass Hunter2
SSLType None
UseNamespace no
# DisableExtension COMPRESS=DEFLATE

Channel "test"
Master ":remote:INBOX"
Slave ":local:test"
Expunge None
Sync PullNew
Patterns *
EOF
	close $fh or BAIL_OUT "close: $!";
	my $cmd = [ $mbsync, qw(-aqq) ];
	my $pid = spawn($cmd, { HOME => $tmpdir }, { 1 => 2 });
	$pids{$pid} = $cmd;
}

while (scalar keys %pids) {
	my $pid = waitpid(-1, 0) or next;
	my $cmd = delete $pids{$pid} or next;
	is($?, 0, join(' ', @$cmd, 'done'));
}

my $sec = $ENV{TEST_PERSIST} // 0;
diag "TEST_PERSIST=$sec";
if ($sec) {
	diag "sleeping ${sec}s, imap://$host:$port/$mailbox available";
	diag "tmpdir=$tmpdir (Maildirs available)";
	diag "stdout=$out";
	diag "stderr=$err";
	diag "pid=$td->{pid}";
	sleep $sec;
}
$td->kill;
$td->join;
is($?, 0, 'no error on -imapd exit');
done_testing;
