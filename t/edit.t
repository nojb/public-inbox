# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# edit frontend behavior test (t/replace.t for backend)
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
require_git(2.6);
require PublicInbox::Inbox;
require PublicInbox::InboxWritable;
require PublicInbox::Config;
use PublicInbox::MID qw(mid_clean);

require_mods('DBD::SQLite');
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = "$tmpdir/v2";
my $ibx = PublicInbox::Inbox->new({
	inboxdir => $inboxdir,
	name => 'test-v2edit',
	version => 2,
	-primary_address => 'test@example.com',
	indexlevel => 'basic',
});
$ibx = PublicInbox::InboxWritable->new($ibx, {nproc=>1});
my $cfgfile = "$tmpdir/config";
local $ENV{PI_CONFIG} = $cfgfile;
my $file = 't/data/0001.patch';
open my $fh, '<', $file or die "open: $!";
my $raw = do { local $/; <$fh> };
my $im = $ibx->importer(0);
my $mime = PublicInbox::Eml->new($raw);
my $mid = mid_clean($mime->header('Message-Id'));
ok($im->add($mime), 'add message to be edited');
$im->done;
my ($in, $out, $err, $cmd, $cur, $t);
my $git = PublicInbox::Git->new("$ibx->{inboxdir}/git/0.git");
my $opt = { 0 => \$in, 1 => \$out, 2 => \$err };

$t = '-F FILE'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/boolean prefix/bool pfx/'";
	$cmd = [ '-edit', "-F$file", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t edit OK");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	like($cur->header('Subject'), qr/bool pfx/, "$t message edited");
	like($out, qr/[a-f0-9]{40}/, "$t shows commit on success");
}

$t = '-m MESSAGE_ID'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/bool pfx/boolean prefix/'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t edit OK");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	like($cur->header('Subject'), qr/boolean prefix/, "$t message edited");
	like($out, qr/[a-f0-9]{40}/, "$t shows commit on success");
}

$t = 'no-op -m MESSAGE_ID'; {
	$in = $out = $err = '';
	my $before = $git->qx(qw(rev-parse HEAD));
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/bool pfx/boolean prefix/'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds");
	my $prev = $cur;
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	is_deeply($cur, $prev, "$t makes no change");
	like($cur->header('Subject'), qr/boolean prefix/,
		"$t does not change message");
	like($out, qr/NONE/, 'noop shows NONE');
	my $after = $git->qx(qw(rev-parse HEAD));
	is($after, $before, 'git head unchanged');
}

$t = 'no-op -m MESSAGE_ID w/Status: header'; { # because mutt does it
	$in = $out = $err = '';
	my $before = $git->qx(qw(rev-parse HEAD));
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/^Subject:.*/Status: RO\\n\$&/'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds");
	my $prev = $cur;
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	is_deeply($cur, $prev, "$t makes no change");
	like($cur->header('Subject'), qr/boolean prefix/,
		"$t does not change message");
	is($cur->header('Status'), undef, 'Status header not added');
	like($out, qr/NONE/, 'noop shows NONE');
	my $after = $git->qx(qw(rev-parse HEAD));
	is($after, $before, 'git head unchanged');
}

$t = '-m MESSAGE_ID can change Received: headers'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/^Subject:.*/Received: x\\n\$&/'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	like($cur->header('Subject'), qr/boolean prefix/,
		"$t does not change Subject");
	is($cur->header('Received'), 'x', 'added Received header');
}

$t = '-m miss'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/boolean/FAIL/'";
	$cmd = [ '-edit', "-m$mid-miss", $inboxdir ];
	ok(!run_script($cmd, undef, $opt), "$t fails on invalid MID");
	like($err, qr/No message found/, "$t shows error");
}

$t = 'non-interactive editor failure'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 'END { exit 1 }'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(!run_script($cmd, undef, $opt), "$t detected");
	like($err, qr/END \{ exit 1 \}' failed:/, "$t shows error");
}

$t = 'mailEditor set in config'; {
	$in = $out = $err = '';
	my $rc = xsys(qw(git config), "--file=$cfgfile",
			'publicinbox.maileditor',
			"$^X -i -p -e 's/boolean prefix/bool pfx/'");
	is($rc, 0, 'set publicinbox.mailEditor');
	local $ENV{MAIL_EDITOR};
	delete $ENV{MAIL_EDITOR};
	local $ENV{GIT_EDITOR} = 'echo should not run';
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t edited message");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	like($cur->header('Subject'), qr/bool pfx/, "$t message edited");
	unlike($out, qr/should not run/, 'did not run GIT_EDITOR');
}

$t = '--raw and mbox escaping'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/^\$/\\nFrom not mbox\\n/'";
	$cmd = [ '-edit', "-m$mid", '--raw', $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	like($cur->body, qr/^From not mbox/sm, 'put "From " line into body');

	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/^>From not/\$& an/'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds with mbox escaping");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	like($cur->body, qr/^From not an mbox/sm,
		'changed "From " line unescaped');

	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/^From not an mbox\\n//s'";
	$cmd = [ '-edit', "-m$mid", '--raw', $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds again");
	$cur = PublicInbox::Eml->new($ibx->msg_by_mid($mid));
	unlike($cur->body, qr/^From not an mbox/sm, "$t restored body");
}

$t = 'reuse Message-ID'; {
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	ok($im->add($mime), "$t and re-add");
	$im->done;
	like($warn[0], qr/reused for mismatched content/, "$t got warning");
}

$t = 'edit ambiguous Message-ID with -m'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/bool pfx/boolean prefix/'";
	$cmd = [ '-edit', "-m$mid", $inboxdir ];
	ok(!run_script($cmd, undef, $opt), "$t fails w/o --force");
	like($err, qr/Multiple messages with different content found matching/,
		"$t shows matches");
	like($err, qr/GIT_DIR=.*git show/is, "$t shows git commands");
}

$t .= ' and --force'; {
	$in = $out = $err = '';
	local $ENV{MAIL_EDITOR} = "$^X -i -p -e 's/^Subject:.*/Subject:x/i'";
	$cmd = [ '-edit', "-m$mid", '--force', $inboxdir ];
	ok(run_script($cmd, undef, $opt), "$t succeeds");
	like($err, qr/Will edit all of them/, "$t notes all will be edited");
	my @dump = $git->qx(qw(cat-file --batch --batch-all-objects));
	chomp @dump;
	is_deeply([grep(/^Subject:/i, @dump)], [qw(Subject:x Subject:x)],
		"$t edited both messages");
}

done_testing();
