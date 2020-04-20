# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Config;
use PublicInbox::TestCommon;
require_git(2.6);
require_mods(qw(Search::Xapian DBD::SQLite Filesys::Notify::Simple));
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = "$tmpdir/v2";
my $maildir = "$tmpdir/md";
use_ok 'PublicInbox::WatchMaildir';
use_ok 'PublicInbox::Emergency';
my $cfgpfx = "publicinbox.test";
my $addr = 'test-public@example.com';
my @cmd = ('-init', '-V2', 'test', $inboxdir,
	'http://example.com/list', $addr);
local $ENV{PI_CONFIG} = "$tmpdir/pi_config";
ok(run_script(\@cmd), 'public-inbox init OK');

my $msg_to = <<EOF;
From: user\@a.com
To: $addr
Subject: address is in to
Message-Id: <to\@a.com>
Date: Sat, 18 Apr 2020 00:00:00 +0000

content1
EOF

my $msg_cc = <<EOF;
From: user1\@a.com
To: user2\@a.com
Cc: $addr
Subject: address is in cc
Message-Id: <cc\@a.com>
Date: Sat, 18 Apr 2020 00:01:00 +0000

content2
EOF

my $msg_none = <<EOF;
From: user1\@a.com
To: user2\@a.com
Cc: user3\@a.com
Subject: address is not in to or cc
Message-Id: <none\@a.com>
Date: Sat, 18 Apr 2020 00:02:00 +0000

content3
EOF

PublicInbox::Emergency->new($maildir)->prepare(\$msg_to);
PublicInbox::Emergency->new($maildir)->prepare(\$msg_cc);
PublicInbox::Emergency->new($maildir)->prepare(\$msg_none);

my $cfg = <<EOF;
$cfgpfx.address=$addr
$cfgpfx.inboxdir=$inboxdir
$cfgpfx.watch=maildir:$maildir
$cfgpfx.watchheader=To:$addr
$cfgpfx.watchheader=Cc:$addr
EOF
my $config = PublicInbox::Config->new(\$cfg);
PublicInbox::WatchMaildir->new($config)->scan('full');
my $ibx = $config->lookup_name('test');
ok($ibx, 'found inbox by name');

my $num = $ibx->mm->num_for('to@a.com');
ok(defined $num, 'Matched for address in To:');
$num = $ibx->mm->num_for('cc@a.com');
ok(defined $num, 'Matched for address in Cc:');
$num = $ibx->mm->num_for('none@a.com');
is($num, undef, 'No match without address in To: or Cc:');

done_testing;
