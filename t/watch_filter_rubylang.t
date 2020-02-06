# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use PublicInbox::TestCommon;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Config;
require_mods(qw(Filesys::Notify::Simple DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::WatchMaildir';
use_ok 'PublicInbox::Emergency';
my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{PI_CONFIG} = "$tmpdir/pi_config";

my @v = qw(V1);
SKIP: {
	if (require_git(2.6, 1)) {
		use_ok 'PublicInbox::V2Writable';
		push @v, 'V2';
	} else {
		skip 'git 2.6+ needed for V2', 40;
	}
}

for my $v (@v) {
	my @warn;
	$SIG{__WARN__} = sub { push @warn, @_ };
	my $cfgpfx = "publicinbox.$v";
	my $inboxdir = "$tmpdir/$v";
	my $maildir = "$tmpdir/md-$v";
	my $spamdir = "$tmpdir/spam-$v";
	my $addr = "test-$v\@example.com";
	my @cmd = ('-init', "-$v", $v, $inboxdir,
		"http://example.com/$v", $addr);
	ok(run_script(\@cmd), 'public-inbox init OK');
	if ($v eq 'V1') {
		ok(run_script(['-index', $inboxdir]), 'v1 indexed');
	}
	PublicInbox::Emergency->new($spamdir);

	for my $i (1..15) {
		my $msg = <<EOF;
From: user\@example.com
To: $addr
Subject: blah $i
X-Mail-Count: $i
Message-Id: <a.$i\@b.com>
Date: Sat, 05 Jan 2019 04:19:17 +0000

something
EOF
		PublicInbox::Emergency->new($maildir)->prepare(\$msg);
	}

	my $spam = <<EOF;
From: spammer\@example.com
To: $addr
Subject: spam
X-Mail-Count: 99
Message-Id: <a.99\@b.com>
Date: Sat, 05 Jan 2019 04:19:17 +0000

spam
EOF
	PublicInbox::Emergency->new($maildir)->prepare(\"$spam");

	my $orig = <<EOF;
$cfgpfx.address=$addr
$cfgpfx.inboxdir=$inboxdir
$cfgpfx.watch=maildir:$maildir
$cfgpfx.filter=PublicInbox::Filter::RubyLang
$cfgpfx.altid=serial:alerts:file=msgmap.sqlite3
publicinboxwatch.watchspam=maildir:$spamdir
EOF
	my $config = PublicInbox::Config->new(\$orig);
	my $ibx = $config->lookup_name($v);
	ok($ibx, 'found inbox by name');

	my $w = PublicInbox::WatchMaildir->new($config);
	for my $i (1..2) {
		$w->scan('full');
	}

	# make sure all serials are searchable:
	my ($tot, $msgs);
	for my $i (1..15) {
		($tot, $msgs) = $ibx->search->query("alerts:$i");
		is($tot, 1, "got one result for alerts:$i");
		is($msgs->[0]->{mid}, "a.$i\@b.com", "got expected MID for $i");
	}
	($tot, undef) = $ibx->search->query('b:spam');
	is($tot, 1, 'got spam message');

	my $nr = unlink <$maildir/new/*>;
	is(16, $nr);
	{
		PublicInbox::Emergency->new($spamdir)->prepare(\$spam);
		my @new = glob("$spamdir/new/*");
		my @p = split(m!/+!, $new[0]);
		ok(link($new[0], "$spamdir/cur/".$p[-1].":2,S"));
		is(unlink($new[0]), 1);
	}
	$w->scan('full');

	$config = PublicInbox::Config->new(\$orig);
	$ibx = $config->lookup_name($v);
	($tot, undef) = $ibx->search->reopen->query('b:spam');
	is($tot, 0, 'spam removed');

	is_deeply([], \@warn, 'no warnings');
}

done_testing();
