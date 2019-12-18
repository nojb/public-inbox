# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Config;
use PublicInbox::TestCommon;
require_git(2.6);
my @mods = qw(DBD::SQLite Search::Xapian);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for mda_filter_rubylang.t" if $@;
}

use_ok 'PublicInbox::V2Writable';
my ($tmpdir, $for_destroy) = tmpdir();
my $pi_config = "$tmpdir/pi_config";
local $ENV{PI_CONFIG} = $pi_config;
local $ENV{PI_EMERGENCY} = "$tmpdir/emergency";
my @cfg = ('git', 'config', "--file=$pi_config");
is(system(@cfg, 'publicinboxmda.spamcheck', 'none'), 0);

for my $v (qw(V1 V2)) {
	my @warn;
	$SIG{__WARN__} = sub { push @warn, @_ };
	my $cfgpfx = "publicinbox.$v";
	my $inboxdir = "$tmpdir/$v";
	my $addr = "test-$v\@example.com";
	my $cmd = [ '-init', "-$v", $v, $inboxdir,
		"http://example.com/$v", $addr ];
	ok(run_script($cmd), 'public-inbox-init');
	ok(run_script(['-index', $inboxdir]), 'public-inbox-index');
	is(system(@cfg, "$cfgpfx.filter", 'PublicInbox::Filter::RubyLang'), 0);
	is(system(@cfg, "$cfgpfx.altid",
		'serial:alerts:file=msgmap.sqlite3'), 0);

	for my $i (1..2) {
		my $env = { ORIGINAL_RECIPIENT => $addr };
		my $opt = { 0 => \(<<EOF) };
From: user\@example.com
To: $addr
Subject: blah $i
X-Mail-Count: $i
Message-Id: <a.$i\@b.com>
Date: Sat, 05 Jan 2019 04:19:17 +0000

something
EOF
		ok(run_script(['-mda'], $env, $opt), 'message delivered');
	}
	my $config = PublicInbox::Config->new;
	my $ibx = $config->lookup_name($v);

	# make sure all serials are searchable:
	my ($tot, $msgs);
	for my $i (1..2) {
		($tot, $msgs) = $ibx->search->query("alerts:$i");
		is($tot, 1, "got one result for alerts:$i");
		is($msgs->[0]->{mid}, "a.$i\@b.com", "got expected MID for $i");
	}
	is_deeply([], \@warn, 'no warnings');

	# TODO: public-inbox-learn doesn't know about filters
	# (but -watch does)
}

done_testing();
