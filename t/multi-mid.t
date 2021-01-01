# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Eml;
use PublicInbox::TestCommon;
use PublicInbox::InboxWritable;
require_git(2.6);
require_mods(qw(DBD::SQLite));
require PublicInbox::SearchIdx;
my $delay = $ENV{TEST_DELAY_CONVERT};

my $addr = 'test@example.com';
my $bad = PublicInbox::Eml->new(<<EOF);
Message-ID: <a\@example.com>
Message-ID: <b\@example.com>
From: a\@example.com
To: $addr
Subject: bad

EOF

my $good = PublicInbox::Eml->new(<<EOF);
Message-ID: <b\@example.com>
From: b\@example.com
To: $addr
Subject: good

EOF

for my $order ([$bad, $good], [$good, $bad]) {
	my $before;
	my ($tmpdir, $for_destroy) = tmpdir();
	my $ibx = PublicInbox::InboxWritable->new({
		inboxdir => "$tmpdir/v1",
		name => 'test-v1',
		indexlevel => 'basic',
		-primary_address => $addr,
	}, my $creat_opt = {});
	my @old;
	if ('setup v1 inbox') {
		my $im = $ibx->importer(0);
		for (@$order) {
			ok($im->add($_), 'added '.$_->header('Subject'));
			sleep($delay) if $delay;
		}
		$im->done;
		my $s = PublicInbox::SearchIdx->new($ibx, 1);
		$s->index_sync;
		$before = [ $ibx->mm->minmax ];
		@old = ($ibx->over->get_art(1), $ibx->over->get_art(2));
		$ibx->cleanup;
	}
	my $rdr = { 1 => \(my $out = ''), 2 => \(my $err = '') };
	my $cmd = [ '-convert', $ibx->{inboxdir}, "$tmpdir/v2" ];
	my $env = { PI_DIR => "$tmpdir/.public-inbox" };
	ok(run_script($cmd, $env, $rdr), 'convert to v2');
	$err =~ s!\AW: $tmpdir/v1 not configured[^\n]+\n!!s;
	is($err, '', 'no errors or warnings from -convert');
	$ibx->{version} = 2;
	$ibx->{inboxdir} = "$tmpdir/v2";
	is_deeply([$ibx->mm->minmax], $before,
		'min, max article numbers unchanged');

	my @v2 = ($ibx->over->get_art(1), $ibx->over->get_art(2));
	is_deeply(\@v2, \@old, 'v2 conversion times match');

	xsys(qw(git clone -sq --mirror), "$tmpdir/v2/git/0.git",
		"$tmpdir/v2-clone/git/0.git") == 0 or die "clone: $?";
	$cmd = [ '-init', '-Lbasic', '-V2', 'v2c', "$tmpdir/v2-clone",
		'http://example.com/v2c', 'v2c@example.com' ];
	ok(run_script($cmd, $env), 'init clone');
	$cmd = [ qw(-index -j0), "$tmpdir/v2-clone" ];
	sleep($delay) if $delay;
	ok(run_script($cmd, $env), 'index the clone');
	$ibx->cleanup;
	$ibx->{inboxdir} = "$tmpdir/v2-clone";
	my @v2c = ($ibx->over->get_art(1), $ibx->over->get_art(2));
	is_deeply(\@v2c, \@old, 'v2 clone times match');
}

done_testing();
