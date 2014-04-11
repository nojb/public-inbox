# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
use Cwd;
use IPC::Run qw(run);

my $mda = "blib/script/public-inbox-mda";
my $learn = "blib/script/public-inbox-learn";
my $tmpdir = tempdir(CLEANUP => 1);
my $home = "$tmpdir/pi-home";
my $pi_home = "$home/.public-inbox";
my $pi_config = "$pi_home/config";
my $maindir = "$tmpdir/main.git";
my $main_bin = getcwd()."/t/main-bin";
my $main_path = "$main_bin:$ENV{PATH}"; # for spamc ham mock
my $fail_bin = getcwd()."/t/fail-bin";
my $fail_path = "$fail_bin:$ENV{PATH}"; # for spamc spam mock
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my $failbox = "$home/fail.mbox";

{
	ok(-x "$main_bin/spamc",
		"spamc ham mock found (run in top of source tree");
	ok(-x "$fail_bin/spamc",
		"spamc mock found (run in top of source tree");
	ok(-x $mda, "$mda is executable");
	is(1, mkdir($home, 0755), "setup ~/ for testing");
	is(1, mkdir($pi_home, 0755), "setup ~/.public-inbox");
	is(0, system(qw(git init -q --bare), $maindir), "git init (main)");

	my %cfg = (
		"$cfgpfx.address" => $addr,
		"$cfgpfx.mainrepo" => $maindir,
	);
	while (my ($k,$v) = each %cfg) {
		is(0, system(qw(git config --file), $pi_config, $k, $v),
			"setup $k");
	}
}

{
	my $good_rev;
	local $ENV{PI_FAILBOX} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{RECIPIENT} = $addr;
	my $simple = Email::Simple->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

EOF
	my $in = $simple->as_string;

	# ensure successful message delivery
	{
		local $ENV{PATH} = $main_path;
		run([$mda], \$in);
		local $ENV{GIT_DIR} = $maindir;
		my $rev = `git rev-list HEAD`;
		like($rev, qr/\A[a-f0-9]{40}/, "good revision committed");
		chomp $rev;
		my $cmt = `git cat-file commit $rev`;
		like($cmt, qr/^author Me <me\@example\.com> 0 \+0000\n/m,
			"author info set correctly");
		like($cmt, qr/^committer test <test-public\@example\.com>/m,
			"committer info set correctly");
		$good_rev = $rev;
	}

	# ensure failures work, fail with bad spamc
	{
		ok(!-e $failbox, "nothing in PI_FAILBOX before");
		local $ENV{PATH} = $fail_path;
		run([$mda], \$in);
		local $ENV{GIT_DIR} = $maindir;
		my @revs = `git rev-list HEAD`;
		is(scalar @revs, 1, "bad revision not committed");
		ok(-s $failbox > 0, "PI_FAILBOX is written to");
	}

	fail_bad_header($good_rev, "bad recipient", <<"");
From: Me <me\@example.com>
To: You <you\@example.com>
Message-Id: <bad-recipient\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

	my $fail = fail_bad_header($good_rev, "duplicate Message-ID", <<"");
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-ID: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

	like($fail->[2], qr/CONFLICT/, "duplicate Message-ID message");

	fail_bad_header($good_rev, "missing From:", <<"");
To: $addr
Message-ID: <missing-from\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

	fail_bad_header($good_rev, "short subject:", <<"");
To: $addr
From: cat\@example.com
Message-ID: <short-subject\@example.com>
Subject: a
Date: Thu, 01 Jan 1970 00:00:00 +0000

	fail_bad_header($good_rev, "no date", <<"");
To: $addr
From: u\@example.com
Message-ID: <no-date\@example.com>
Subject: hihi

	fail_bad_header($good_rev, "bad date", <<"");
To: $addr
From: u\@example.com
Message-ID: <bad-date\@example.com>
Subject: hihi
Date: deadbeef

}

# spam training
{
	local $ENV{PI_FAILBOX} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{RECIPIENT} = $addr;
	local $ENV{PATH} = $main_path;
	my $mid = 'spam-train@example.com';
	my $simple = Email::Simple->new(<<EOF);
From: Spammer <spammer\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-ID: <$mid>
Subject: this message will be trained as spam
Date: Thu, 01 Jan 1970 00:00:00 +0000

EOF
	my $in = $simple->as_string;

	{
		# deliver the spam message, first
		run([$mda], \$in);
		my $msg = `ssoma cat $mid $maindir`;
		like($msg, qr/\Q$mid\E/, "message delivered");

		# now train it
		local $ENV{GIT_AUTHOR_EMAIL} = 'trainer@example.com';
		local $ENV{GIT_COMMITTER_EMAIL} = 'trainer@example.com';
		run([$learn, "spam"], \$msg);
		is($?, 0, "no failure from learning spam");
		run([$learn, "spam"], \$msg);
		is($?, 0, "no failure from learning spam idempotently");
	}
}

# train ham message
{
	local $ENV{PI_FAILBOX} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{RECIPIENT} = $addr;
	local $ENV{PATH} = $main_path;
	my $mid = 'ham-train@example.com';
	my $simple = Email::Simple->new(<<EOF);
From: False-positive <hammer\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-ID: <$mid>
Subject: this message will be trained as spam
Date: Thu, 01 Jan 1970 00:00:00 +0000

EOF
	my $in = $simple->as_string;

	# now train it
	local $ENV{GIT_AUTHOR_EMAIL} = 'trainer@example.com';
	local $ENV{GIT_COMMITTER_EMAIL} = 'trainer@example.com';
	run([$learn, "ham"], \$in);
	is($?, 0, "learned ham without failure");
	my $msg = `ssoma cat $mid $maindir`;
	like($msg, qr/\Q$mid\E/, "ham message delivered");
	run([$learn, "ham"], \$in);
	is($?, 0, "learned ham idempotently ");
}

done_testing();

sub fail_bad_header {
	my ($good_rev, $msg, $in) = @_;
	open my $fh, '>', $failbox or die "failed to open $failbox: $!\n";
	close $fh or die "failed to close $failbox: $!\n";
	my ($out, $err) = ("", "");
	local $ENV{PATH} = $main_path;
	run([$mda], \$in, \$out, \$err);
	local $ENV{GIT_DIR} = $maindir;
	my $rev = `git rev-list HEAD`;
	chomp $rev;
	is($rev, $good_rev, "bad revision not commited ($msg)");
	ok(-s $failbox > 0, "PI_FAILBOX is written to ($msg)");
	[ $in, $out, $err ];
}
