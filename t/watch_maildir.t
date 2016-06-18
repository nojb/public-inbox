# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use File::Temp qw/tempdir/;
use Email::MIME;
use PublicInbox::Config;

my $tmpdir = tempdir('watch_maildir-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/test.git";
my $maildir = "$tmpdir/md";
use_ok 'PublicInbox::WatchMaildir';
use_ok 'PublicInbox::Emergency';
my $cfgpfx = "publicinbox.test";
my $addr = 'test-public@example.com';
is(system(qw(git init -q --bare), $git_dir), 0, 'initialized git dir');

my $msg = <<EOF;
From: user\@example.com
To: $addr
Subject: spam
Message-Id: <a\@b.com>
Date: Sat, 18 Jun 2016 00:00:00 +0000

msg
EOF
PublicInbox::Emergency->new($maildir)->prepare(\$msg);

my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => $addr,
	"$cfgpfx.mainrepo" => $git_dir,
	"$cfgpfx.watch" => "maildir:$maildir",
});

PublicInbox::WatchMaildir->new($config)->scan;
my $git = PublicInbox::Git->new($git_dir);
my @list = $git->qx(qw(rev-list refs/heads/master));
is(scalar @list, 1, 'one revision in rev-list');

done_testing;
