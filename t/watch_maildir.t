# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use File::Temp qw/tempdir/;
use Email::MIME;
use PublicInbox::Config;

my $tmpdir = tempdir('watch_maildir-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/test.git";
my $maildir = "$tmpdir/md";
my $spamdir = "$tmpdir/spam";
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

something
EOF
PublicInbox::Emergency->new($maildir)->prepare(\$msg);
ok(POSIX::mkfifo("$maildir/cur/fifo", 0777));
my $sem = PublicInbox::Emergency->new($spamdir); # create dirs

my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => $addr,
	"$cfgpfx.mainrepo" => $git_dir,
	"$cfgpfx.watch" => "maildir:$maildir",
	"$cfgpfx.filter" => 'PublicInbox::Filter::Vger',
	"publicinboxlearn.watchspam" => "maildir:$spamdir",
});

PublicInbox::WatchMaildir->new($config)->scan;
my $git = PublicInbox::Git->new($git_dir);
my @list = $git->qx(qw(rev-list refs/heads/master));
is(scalar @list, 1, 'one revision in rev-list');

my $write_spam = sub {
	is(scalar glob("$spamdir/new/*"), undef, 'no spam existing');
	$sem->prepare(\$msg);
	$sem->commit;
	my @new = glob("$spamdir/new/*");
	is(scalar @new, 1);
	my @p = split(m!/+!, $new[0]);
	ok(link($new[0], "$spamdir/cur/".$p[-1].":2,S"));
	is(unlink($new[0]), 1);
};
$write_spam->();
is(unlink(glob("$maildir/new/*")), 1, 'unlinked old spam');
PublicInbox::WatchMaildir->new($config)->scan;
@list = $git->qx(qw(rev-list refs/heads/master));
is(scalar @list, 2, 'two revisions in rev-list');
@list = $git->qx(qw(ls-tree -r --name-only refs/heads/master));
is(scalar @list, 0, 'tree is empty');

# check with scrubbing
{
	$msg .= qq(--
To unsubscribe from this list: send the line "unsubscribe git" in
the body of a message to majordomo\@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html\n);
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	PublicInbox::WatchMaildir->new($config)->scan;
	@list = $git->qx(qw(ls-tree -r --name-only refs/heads/master));
	is(scalar @list, 1, 'tree has one file');
	my $mref = $git->cat_file('HEAD:'.$list[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');

	is(unlink(glob("$maildir/new/*")), 1, 'unlinked spam');
	$write_spam->();
	PublicInbox::WatchMaildir->new($config)->scan;
	@list = $git->qx(qw(ls-tree -r --name-only refs/heads/master));
	is(scalar @list, 0, 'tree is empty');
	@list = $git->qx(qw(rev-list refs/heads/master));
	is(scalar @list, 4, 'four revisions in rev-list');
}

done_testing;
