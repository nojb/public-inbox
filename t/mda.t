# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use Email::Filter;
use File::Temp qw/tempdir/;
use Cwd;
use IPC::Run qw(run);

my $mda = "blib/script/public-inbox-mda";
my $learn = "blib/script/public-inbox-learn";
my $tmpdir = tempdir('pi-mda-XXXXXX', TMPDIR => 1, CLEANUP => 1);
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
my $mime;

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

local $ENV{GIT_COMMITTER_NAME} = eval {
	use PublicInbox::MDA;
	use Encode qw/encode/;
	my $mbox = 't/utf8.mbox';
	open(my $fh, '<', $mbox) or die "failed to open mbox: $mbox\n";
	my $str = eval { local $/; <$fh> };
	close $fh;
	my $msg = Email::Filter->new(data => $str);
	$msg = Email::MIME->new($msg->simple->as_string);
	my ($author, $email, $date) = PublicInbox::MDA->author_info($msg);
	is('El&#233;anor',
		encode('us-ascii', my $tmp = $author, Encode::HTMLCREF),
		'HTML conversion is correct');
	is($email, 'e@example.com', 'email parsed correctly');
	is($date, 'Thu, 01 Jan 1970 00:00:00 +0000',
		'message date parsed correctly');
	$author;
};
die $@ if $@;

{
	my $good_rev;
	local $ENV{PI_EMERGENCY} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{ORIGINAL_RECIPIENT} = $addr;
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
		ok(!-e $failbox, "nothing in PI_EMERGENCY before");
		local $ENV{PATH} = $fail_path;
		run([$mda], \$in);
		local $ENV{GIT_DIR} = $maindir;
		my @revs = `git rev-list HEAD`;
		is(scalar @revs, 1, "bad revision not committed");
		ok(-s $failbox > 0, "PI_EMERGENCY is written to");
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
	local $ENV{PI_EMERGENCY} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{ORIGINAL_RECIPIENT} = $addr;
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
	local $ENV{PI_EMERGENCY} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{ORIGINAL_RECIPIENT} = $addr;
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
	# these should be overridden
	local $ENV{GIT_AUTHOR_EMAIL} = 'trainer@example.com';
	local $ENV{GIT_COMMITTER_EMAIL} = 'trainer@example.com';

	run([$learn, "ham"], \$in);
	is($?, 0, "learned ham without failure");
	my $msg = `ssoma cat $mid $maindir`;
	like($msg, qr/\Q$mid\E/, "ham message delivered");
	run([$learn, "ham"], \$in);
	is($?, 0, "learned ham idempotently ");

	# ensure trained email is filtered, too
	my $html_body = "<html><body>hi</body></html>";
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'text/html; charset=UTF-8',
				encoding => 'base64',
			},
			body => $html_body,
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				encoding => 'quoted-printable',
			},
			body => 'hi = "bye"',
		)
	];
	$mid = 'multipart-html-sucks@11';
	$mime = Email::MIME->create(
		header_str => [
		  From => 'a@example.com',
		  Subject => 'blah',
		  Cc => $addr,
		  'Message-ID' => "<$mid>",
		  'Content-Type' => 'multipart/alternative',
		],
		parts => $parts,
	);

	{
		$in = $mime->as_string;
		run([$learn, "ham"], \$in);
		is($?, 0, "learned ham without failure");
		$msg = `ssoma cat $mid $maindir`;
		like($msg, qr/<\Q$mid\E>/, "ham message delivered");
		unlike($msg, qr/<html>/i, '<html> filtered');
	}
}

# faildir - emergency destination is maildir
{
	my $faildir= "$home/faildir/";
	local $ENV{PI_EMERGENCY} = $faildir;
	local $ENV{HOME} = $home;
	local $ENV{ORIGINAL_RECIPIENT} = $addr;
	local $ENV{PATH} = $fail_path;
	my $in = <<EOF;
From: Faildir <faildir\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-ID: <faildir\@example.com>
Subject: faildir subject
Date: Thu, 01 Jan 1970 00:00:00 +0000

EOF
	run([$mda], \$in);
	ok(-d $faildir, "emergency exists");
	my @new = glob("$faildir/new/*");
	is(scalar(@new), 1, "message delivered");
	is(unlink(@new), 1, "removed emergency message");

	local $ENV{PATH} = $main_path;
	$in = <<EOF;
From: Faildir <faildir\@example.com>
To: $addr
Content-Type: text/html
Message-ID: <faildir\@example.com>
Subject: faildir subject
Date: Thu, 01 Jan 1970 00:00:00 +0000

<html><body>bad</body></html>
EOF
	my $out = '';
	my $err = '';
	run([$mda], \$in, \$out, \$err);
	isnt($?, 0, "mda exited with failure");
	is(length $out, 0, 'nothing in stdout');
	isnt(length $err, 0, 'error message in stderr');

	@new = glob("$faildir/new/*");
	is(scalar(@new), 0, "new message did not show up");

	# reject multipart again
	$in = $mime->as_string;
	$err = '';
	run([$mda], \$in, \$out, \$err);
	isnt($?, 0, "mda exited with failure");
	is(length $out, 0, 'nothing in stdout');
	isnt(length $err, 0, 'error message in stderr');
	@new = glob("$faildir/new/*");
	is(scalar(@new), 0, "new message did not show up");
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
	ok(-s $failbox > 0, "PI_EMERGENCY is written to ($msg)");
	[ $in, $out, $err ];
}
