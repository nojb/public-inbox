# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use File::Temp qw/tempdir/;
use PublicInbox::MIME;
use Cwd;
use PublicInbox::Config;
my @mods = qw(Filesys::Notify::Simple PublicInbox::V2Writable);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for watch_maildir_v2.t" if $@;
}

my $tmpdir = tempdir('watch_maildir-v2-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $mainrepo = "$tmpdir/v2";
my $maildir = "$tmpdir/md";
my $spamdir = "$tmpdir/spam";
use_ok 'PublicInbox::WatchMaildir';
use_ok 'PublicInbox::Emergency';
my $cfgpfx = "publicinbox.test";
my $addr = 'test-public@example.com';
my @cmd = ('blib/script/public-inbox-init', '-V2', 'test', $mainrepo,
	'http://example.com/v2list', $addr);
local $ENV{PI_CONFIG} = "$tmpdir/pi_config";
is(system(@cmd), 0, 'public-inbox init OK');

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

my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => $addr,
	"$cfgpfx.mainrepo" => $mainrepo,
	"$cfgpfx.watch" => "maildir:$maildir",
	"$cfgpfx.filter" => 'PublicInbox::Filter::Vger',
	"publicinboxlearn.watchspam" => "maildir:$spamdir",
});
my $ibx = $config->lookup_name('test');
ok($ibx, 'found inbox by name');
my $srch = $ibx->search;

PublicInbox::WatchMaildir->new($config)->scan('full');
my $res = $srch->reopen->query('');
is($res->{total}, 1, 'got one revision');

# my $git = PublicInbox::Git->new("$mainrepo/git/0.git");
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
is($srch->reopen->query('')->{total}, 0, 'deleted file');

# check with scrubbing
{
	$msg .= qq(--
To unsubscribe from this list: send the line "unsubscribe git" in
the body of a message to majordomo\@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html\n);
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	PublicInbox::WatchMaildir->new($config)->scan('full');
	$res = $srch->reopen->query('');
	is($res->{total}, 1, 'got one file back');
	my $mref = $ibx->msg_by_smsg($res->{msgs}->[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');

	is(unlink(glob("$maildir/new/*")), 1, 'unlinked spam');
	$write_spam->();
	PublicInbox::WatchMaildir->new($config)->scan('full');
	$res = $srch->reopen->query('');
	is($res->{total}, 0, 'inbox is empty again');
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
	$res = $srch->reopen->query('');
	is($res->{total}, 0, 'inbox is still empty');
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
	$res = $srch->reopen->query('');
	is($res->{total}, 1, 'inbox has one mail after spamc OK-ed a message');
	my $mref = $ibx->msg_by_smsg($res->{msgs}->[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');
}

done_testing;
