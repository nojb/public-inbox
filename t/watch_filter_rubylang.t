# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
require './t/common.perl';
use Test::More;
use File::Temp qw/tempdir/;
use PublicInbox::MIME;
use PublicInbox::Config;
my @mods = qw(Filesys::Notify::Simple DBD::SQLite Search::Xapian);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for watch_filter_rubylang_v2.t" if $@;
}

use_ok 'PublicInbox::WatchMaildir';
use_ok 'PublicInbox::Emergency';
my $tmpdir = tempdir('watch-XXXXXX', TMPDIR => 1, CLEANUP => 1);
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
	my $mainrepo = "$tmpdir/$v";
	my $maildir = "$tmpdir/md-$v";
	my $spamdir = "$tmpdir/spam-$v";
	my $addr = "test-$v\@example.com";
	my @cmd = ('blib/script/public-inbox-init', "-$v", $v, $mainrepo,
		"http://example.com/$v", $addr);
	is(system(@cmd), 0, 'public-inbox init OK');
	if ($v eq 'V1') {
		is(system('blib/script/public-inbox-index', $mainrepo), 0);
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

	my %orig = (
		"$cfgpfx.address" => $addr,
		"$cfgpfx.mainrepo" => $mainrepo,
		"$cfgpfx.watch" => "maildir:$maildir",
		"$cfgpfx.filter" => 'PublicInbox::Filter::RubyLang',
		"$cfgpfx.altid" => 'serial:alerts:file=msgmap.sqlite3',
		"publicinboxwatch.watchspam" => "maildir:$spamdir",
	);
	my $config = PublicInbox::Config->new({%orig});
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

	$config = PublicInbox::Config->new({%orig});
	$ibx = $config->lookup_name($v);
	($tot, undef) = $ibx->search->reopen->query('b:spam');
	is($tot, 0, 'spam removed');

	is_deeply([], \@warn, 'no warnings');
}

done_testing();
