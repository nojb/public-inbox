# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Eml;
use Cwd;
use PublicInbox::Config;
use PublicInbox::TestCommon;
use PublicInbox::Import;
require_git(2.6);
require_mods(qw(Search::Xapian DBD::SQLite));
require PublicInbox::V2Writable;
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = "$tmpdir/v2";
my $maildir = "$tmpdir/md";
my $spamdir = "$tmpdir/spam";
use_ok 'PublicInbox::WatchMaildir';
use_ok 'PublicInbox::Emergency';
my $cfgpfx = "publicinbox.test";
my $addr = 'test-public@example.com';
my @cmd = ('-init', '-V2', 'test', $inboxdir,
	'http://example.com/v2list', $addr);
local $ENV{PI_CONFIG} = "$tmpdir/pi_config";
ok(run_script(\@cmd), 'public-inbox init OK');

my $msg = <<EOF;
From: user\@example.com
To: $addr
Subject: spam
Message-Id: <a\@b.com>
Date: Sat, 18 Jun 2016 00:00:00 +0000

something
EOF
PublicInbox::Emergency->new($maildir)->prepare(\$msg);
ok(POSIX::mkfifo("$maildir/cur/fifo", 0777),
	'create FIFO to ensure we do not get stuck on it :P');
my $sem = PublicInbox::Emergency->new($spamdir); # create dirs

my $orig = <<EOF;
$cfgpfx.address=$addr
$cfgpfx.inboxdir=$inboxdir
$cfgpfx.watch=maildir:$maildir
$cfgpfx.filter=PublicInbox::Filter::Vger
publicinboxlearn.watchspam=maildir:$spamdir
EOF
my $config = PublicInbox::Config->new(\$orig);
my $ibx = $config->lookup_name('test');
ok($ibx, 'found inbox by name');
my $srch = $ibx->search;

PublicInbox::WatchMaildir->new($config)->scan('full');
my ($total, undef) = $srch->reopen->query('');
is($total, 1, 'got one revision');

# my $git = PublicInbox::Git->new("$inboxdir/git/0.git");
# my @list = $git->qx(qw(rev-list refs/heads/master));
# is(scalar @list, 1, 'one revision in rev-list');

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
PublicInbox::WatchMaildir->new($config)->scan('full');
is(($srch->reopen->query(''))[0], 0, 'deleted file');

# check with scrubbing
{
	$msg .= qq(--
To unsubscribe from this list: send the line "unsubscribe git" in
the body of a message to majordomo\@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html\n);
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	PublicInbox::WatchMaildir->new($config)->scan('full');
	my ($nr, $msgs) = $srch->reopen->query('');
	is($nr, 1, 'got one file back');
	my $mref = $ibx->msg_by_smsg($msgs->[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');

	is(unlink(glob("$maildir/new/*")), 1, 'unlinked spam');
	$write_spam->();
	PublicInbox::WatchMaildir->new($config)->scan('full');
	($nr, $msgs) = $srch->reopen->query('');
	is($nr, 0, 'inbox is empty again');
}

{
	my $fail_bin = getcwd()."/t/fail-bin";
	ok(-x "$fail_bin/spamc", "mock spamc exists");
	my $fail_path = "$fail_bin:$ENV{PATH}"; # for spamc ham mock
	local $ENV{PATH} = $fail_path;
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	$config->{'publicinboxwatch.spamcheck'} = 'spamc';
	{
		local $SIG{__WARN__} = sub {}; # quiet spam check warning
		PublicInbox::WatchMaildir->new($config)->scan('full');
	}
	my ($nr, $msgs) = $srch->reopen->query('');
	is($nr, 0, 'inbox is still empty');
	is(unlink(glob("$maildir/new/*")), 1);
}

{
	my $main_bin = getcwd()."/t/main-bin";
	ok(-x "$main_bin/spamc", "mock spamc exists");
	my $main_path = "$main_bin:$ENV{PATH}"; # for spamc ham mock
	local $ENV{PATH} = $main_path;
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	$config->{'publicinboxwatch.spamcheck'} = 'spamc';
	PublicInbox::WatchMaildir->new($config)->scan('full');
	my ($nr, $msgs) = $srch->reopen->query('');
	is($nr, 1, 'inbox has one mail after spamc OK-ed a message');
	my $mref = $ibx->msg_by_smsg($msgs->[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');
	delete $config->{'publicinboxwatch.spamcheck'};
}

{
	my $patch = 't/data/0001.patch';
	open my $fh, '<', $patch or die "failed to open $patch: $!\n";
	$msg = do { local $/; <$fh> };
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	PublicInbox::WatchMaildir->new($config)->scan('full');
	my ($nr, $msgs) = $srch->reopen->query('dfpost:6e006fd7');
	is($nr, 1, 'diff postimage found');
	my $post = $msgs->[0];
	($nr, $msgs) = $srch->query('dfpre:090d998b6c2c');
	is($nr, 1, 'diff preimage found');
	is($post->{blob}, $msgs->[0]->{blob}, 'same message');
}

# multiple inboxes in the same maildir
{
	my $v1repo = "$tmpdir/v1";
	my $v1pfx = "publicinbox.v1";
	my $v1addr = 'v1-public@example.com';
	PublicInbox::Import::init_bare($v1repo);
	my $cfg2 = <<EOF;
$orig$v1pfx.address=$v1addr
$v1pfx.inboxdir=$v1repo
$v1pfx.watch=maildir:$maildir
EOF
	my $config = PublicInbox::Config->new(\$cfg2);
	my $both = <<EOF;
From: user\@example.com
To: $addr, $v1addr
Subject: both
Message-Id: <both\@b.com>
Date: Sat, 18 Jun 2016 00:00:00 +0000

both
EOF
	PublicInbox::Emergency->new($maildir)->prepare(\$both);
	PublicInbox::WatchMaildir->new($config)->scan('full');
	my ($total, $msgs) = $srch->reopen->query('m:both@b.com');
	my $v1 = $config->lookup_name('v1');
	my $msg = $v1->git->cat_file($msgs->[0]->{blob});
	is($both, $$msg, 'got original message back from v1');
	$msg = $ibx->git->cat_file($msgs->[0]->{blob});
	is($both, $$msg, 'got original message back from v2');
}

{
	my $want = <<'EOF';
From: <u@example.com>
List-Id: <i.want.you.to.want.me>
Message-ID: <do.want@example.com>
EOF
	my $do_not_want = <<'EOF';
From: <u@example.com>
List-Id: <do.not.want>
X-Mailing-List: no@example.com
Message-ID: <do.not.want@example.com>
EOF
	my $cfg = $orig."$cfgpfx.listid=i.want.you.to.want.me\n";
	PublicInbox::Emergency->new($maildir)->prepare(\$want);
	PublicInbox::Emergency->new($maildir)->prepare(\$do_not_want);
	my $config = PublicInbox::Config->new(\$cfg);
	PublicInbox::WatchMaildir->new($config)->scan('full');
	$ibx = $config->lookup_name('test');
	my $num = $ibx->mm->num_for('do.want@example.com');
	ok(defined $num, 'List-ID matched for watch');
	$num = $ibx->mm->num_for('do.not.want@example.com');
	is($num, undef, 'unaccepted List-ID matched for watch');

	$cfg = $orig."$cfgpfx.watchheader=X-Mailing-List:no\@example.com\n";
	$config = PublicInbox::Config->new(\$cfg);
	PublicInbox::WatchMaildir->new($config)->scan('full');
	$ibx = $config->lookup_name('test');
	$num = $ibx->mm->num_for('do.not.want@example.com');
	ok(defined $num, 'X-Mailing-List matched');
}

done_testing;
