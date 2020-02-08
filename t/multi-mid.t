# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use PublicInbox::MIME;
use PublicInbox::TestCommon;
use PublicInbox::InboxWritable;
require_git(2.6);
require_mods(qw(DBD::SQLite));
require PublicInbox::SearchIdx;

my $addr = 'test@example.com';
my $bad = PublicInbox::MIME->new(<<EOF);
Message-ID: <a\@example.com>
Message-ID: <b\@example.com>
From: a\@example.com
To: $addr
Date: Fri, 02 Oct 1993 00:00:00 +0000
Subject: bad

EOF

my $good = PublicInbox::MIME->new(<<EOF);
Message-ID: <b\@example.com>
Date: Fri, 02 Oct 1993 00:00:00 +0000
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
	if ('setup v1 inbox') {
		my $im = $ibx->importer(0);
		ok($im->add($_), 'added '.$_->header('Subject')) for @$order;
		$im->done;
		my $s = PublicInbox::SearchIdx->new($ibx, 1);
		$s->index_sync;
		$before = [ $ibx->mm->minmax ];
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
}

done_testing();
