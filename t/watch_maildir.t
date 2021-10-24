# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Eml;
use Cwd;
use PublicInbox::Config;
use PublicInbox::TestCommon;
use PublicInbox::Import;
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/test.git";
my $maildir = "$tmpdir/md";
my $spamdir = "$tmpdir/spam";
use_ok 'PublicInbox::Watch';
use_ok 'PublicInbox::Emergency';
my $cfgpfx = "publicinbox.test";
my $addr = 'test-public@example.com';
my $default_branch = PublicInbox::Import::default_branch;
PublicInbox::Import::init_bare($git_dir);

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

{
	my @w;
	local $SIG{__WARN__} = sub { push @w, @_ };
	my $cfg = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=$addr
$cfgpfx.inboxdir=$git_dir
$cfgpfx.watch=maildir:$spamdir
publicinboxlearn.watchspam=maildir:$spamdir
EOF
	my $wm = PublicInbox::Watch->new($cfg);
	is(scalar grep(/is a spam folder/, @w), 1, 'got warning about spam');
	is_deeply($wm->{mdmap}, { "$spamdir/cur" => 'watchspam' },
		'only got the spam folder to watch');
}

my $cfg_path = "$tmpdir/config";
{
	open my $fh, '>', $cfg_path or BAIL_OUT $!;
	print $fh <<EOF or BAIL_OUT $!;
[publicinbox "test"]
	address = $addr
	inboxdir = $git_dir
	watch = maildir:$maildir
	filter = PublicInbox::Filter::Vger
[publicinboxlearn]
	watchspam = maildir:$spamdir
EOF
	close $fh or BAIL_OUT $!;
}

my $cfg = PublicInbox::Config->new($cfg_path);
PublicInbox::Watch->new($cfg)->scan('full');
my $git = PublicInbox::Git->new($git_dir);
my @list = $git->qx('rev-list', $default_branch);
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
PublicInbox::Watch->new($cfg)->scan('full');
@list = $git->qx('rev-list', $default_branch);
is(scalar @list, 2, 'two revisions in rev-list');
@list = $git->qx('ls-tree', '-r', '--name-only', $default_branch);
is(scalar @list, 0, 'tree is empty');
is(unlink(glob("$spamdir/cur/*")), 1, 'unlinked trained spam');

# check with scrubbing
{
	$msg .= qq(--
To unsubscribe from this list: send the line "unsubscribe git" in
the body of a message to majordomo\@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html\n);
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	PublicInbox::Watch->new($cfg)->scan('full');
	@list = $git->qx('ls-tree', '-r', '--name-only', $default_branch);
	is(scalar @list, 1, 'tree has one file');
	my $mref = $git->cat_file('HEAD:'.$list[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');

	is(unlink(glob("$maildir/new/*")), 1, 'unlinked spam');
	$write_spam->();
	PublicInbox::Watch->new($cfg)->scan('full');
	@list = $git->qx('ls-tree', '-r', '--name-only', $default_branch);
	is(scalar @list, 0, 'tree is empty');
	@list = $git->qx('rev-list', $default_branch);
	is(scalar @list, 4, 'four revisions in rev-list');
	is(unlink(glob("$spamdir/cur/*")), 1, 'unlinked trained spam');
}

{
	my $fail_bin = getcwd()."/t/fail-bin";
	ok(-x "$fail_bin/spamc", "mock spamc exists");
	my $fail_path = "$fail_bin:$ENV{PATH}"; # for spamc ham mock
	local $ENV{PATH} = $fail_path;
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	$cfg->{'publicinboxwatch.spamcheck'} = 'spamc';
	{
		local $SIG{__WARN__} = sub {}; # quiet spam check warning
		PublicInbox::Watch->new($cfg)->scan('full');
	}
	@list = $git->qx('ls-tree', '-r', '--name-only', $default_branch);
	is(scalar @list, 0, 'tree has no files spamc checked');
	is(unlink(glob("$maildir/new/*")), 1);
}

{
	my $main_bin = getcwd()."/t/main-bin";
	ok(-x "$main_bin/spamc", "mock spamc exists");
	my $main_path = "$main_bin:$ENV{PATH}"; # for spamc ham mock
	local $ENV{PATH} = $main_path;
	PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	$cfg->{'publicinboxwatch.spamcheck'} = 'spamc';
	@list = $git->qx('ls-tree', '-r', '--name-only', $default_branch);
	PublicInbox::Watch->new($cfg)->scan('full');
	@list = $git->qx('ls-tree', '-r', '--name-only', $default_branch);
	is(scalar @list, 1, 'tree has one file after spamc checked');

	# XXX: workaround some weird caching/memoization in cat-file,
	# shouldn't be an issue in real-world use, though...
	$git = PublicInbox::Git->new($git_dir);

	my $mref = $git->cat_file($default_branch.':'.$list[0]);
	like($$mref, qr/something\n\z/s, 'message scrubbed on import');
}

# end-to-end test which actually uses inotify/kevent
{
	my $env = { PI_CONFIG => $cfg_path };
	$git->cleanup;

	# n.b. --no-scan is only intended for testing atm
	my $wm = start_script([qw(-watch --no-scan)], $env);
	my $eml = eml_load('t/data/0001.patch');
	$eml->header_set('Cc', $addr);
	my $em = PublicInbox::Emergency->new($maildir);
	$em->prepare(\($eml->as_string));

	use_ok 'PublicInbox::InboxIdle';
	use_ok 'PublicInbox::DS';
	my $delivered = 0;
	my $cb = sub {
		my ($ibx) = @_;
		diag "message delivered to `$ibx->{name}'";
		$delivered++;
	};
	PublicInbox::DS->Reset;
	my $ii = PublicInbox::InboxIdle->new($cfg);
	my $obj = bless \$cb, 'PublicInbox::TestCommon::InboxWakeup';
	$cfg->each_inbox(sub { $_[0]->subscribe_unlock('ident', $obj) });
	PublicInbox::DS->SetPostLoopCallback(sub { $delivered == 0 });

	# wait for -watch to setup inotify watches
	my $sleep = 1;
	if (eval { require Linux::Inotify2 } && -d "/proc/$wm->{pid}/fd") {
		my $end = time + 2;
		my (@ino, @ino_info);
		do {
			@ino = grep {
				(readlink($_)//'') =~ /\binotify\b/
			} glob("/proc/$wm->{pid}/fd/*");
		} until (@ino || time > $end || !tick);
		if (scalar(@ino) == 1) {
			my $ino_fd = (split('/', $ino[0]))[-1];
			my $ino_fdinfo = "/proc/$wm->{pid}/fdinfo/$ino_fd";
			while (time < $end && open(my $fh, '<', $ino_fdinfo)) {
				@ino_info = grep(/^inotify wd:/, <$fh>);
				last if @ino_info >= 3;
				tick;
			}
			$sleep = undef if @ino_info >= 3;
		}
	}
	if ($sleep) {
		diag "waiting ${sleep}s for -watch to start up";
		sleep $sleep;
	}

	$em->commit; # wake -watch up
	diag 'waiting for -watch to import new message';
	PublicInbox::DS::event_loop();
	$wm->kill;
	$wm->join;
	$ii->close;
	PublicInbox::DS->Reset;
	my $head = $git->qx(qw(cat-file commit HEAD));
	my $subj = $eml->header('Subject');
	like($head, qr/^\Q$subj\E/sm, 'new commit made');
}

sub is_maildir {
	my ($dir) = @_;
	PublicInbox::Watch::is_maildir($dir);
}

is(is_maildir('maildir:/hello//world'), '/hello/world', 'extra slash gone');
is(is_maildir('maildir:/hello/world/'), '/hello/world', 'trailing slash gone');
is(is_maildir('faildir:/hello/world/'), undef, 'non-maildir rejected');

done_testing;
