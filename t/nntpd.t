# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
eval { require PublicInbox::SearchIdx };
plan skip_all => "Xapian missing for nntpd" if $@;
eval { require PublicInbox::Msgmap };
plan skip_all => "DBD::SQLite missing for nntpd" if $@;
use Cwd;
use Email::Simple;
use IO::Socket;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
use File::Temp qw/tempdir/;
use Net::NNTP;
use IPC::Run qw(run);
use Data::Dumper;

my $tmpdir = tempdir(CLEANUP => 1);
my $home = "$tmpdir/pi-home";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $pi_home = "$home/.public-inbox";
my $pi_config = "$pi_home/config";
my $maindir = "$tmpdir/main.git";
my $main_bin = getcwd()."/t/main-bin";
my $main_path = "$main_bin:$ENV{PATH}"; # for spamc ham mock
my $group = 'test-nntpd';
my $addr = $group . '@example.com';
my $cfgpfx = "publicinbox.$group";
my $failbox = "$home/fail.mbox";
local $ENV{PI_EMERGENCY} = $failbox;
my $mda = 'blib/script/public-inbox-mda';
my $nntpd = 'blib/script/public-inbox-nntpd';
my $init = 'blib/script/public-inbox-init';
my $index = 'blib/script/public-inbox-index';

my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Type => SOCK_STREAM,
	Listen => 1024,
);
my $sock = IO::Socket::INET->new(%opts);
plan skip_all => 'sock fd!=3, cannot test nntpd integration' if fileno($sock) != 3;
my $pid;
END { kill 'TERM', $pid if defined $pid };
{
	local $ENV{HOME} = $home;
	system($init, $group, $maindir, 'http://example.com/', $addr);

	# ensure successful message delivery
	{
		local $ENV{ORIGINAL_RECIPIENT} = $addr;
		my $simple = Email::Simple->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <nntp\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

nntp
EOF
		my $in = $simple->as_string;
		local $ENV{PATH} = $main_path;
		IPC::Run::run([$mda], \$in);
		is(0, $?, 'ran MDA correctly');
		is(0, system($index, $maindir), 'indexed git dir');
	}

	ok($sock, 'sock created');
	$! = 0;
	my $fl = fcntl($sock, F_GETFD, 0);
	ok(! $!, 'no error from fcntl(F_GETFD)');
	is($fl, FD_CLOEXEC, 'cloexec set by default (Perl behavior)');
	$pid = fork;
	if ($pid == 0) {
		# pretend to be systemd
		fcntl($sock, F_SETFD, $fl &= ~FD_CLOEXEC);
		$ENV{LISTEN_PID} = $$;
		$ENV{LISTEN_FDS} = 1;
		exec $nntpd, "--stdout=$out", "--stderr=$err";
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked nntpd process successfully');
	$! = 0;
	ok(! $!, 'no error from fcntl(F_SETFD)');
	fcntl($sock, F_SETFD, $fl |= FD_CLOEXEC);
	my $n = Net::NNTP->new($sock->sockhost . ':' . $sock->sockport);
	my $list = $n->list;
	is_deeply($list, { $group => [ qw(1 1 n) ] }, 'LIST works');
	is_deeply([$n->group($group)], [ qw(0 1 1), $group ], 'GROUP works');

	# TODO: upgrades and such

	ok(kill('TERM', $pid), 'killed nntpd');
	$pid = undef;
	waitpid(-1, 0);
}

done_testing();

1;
