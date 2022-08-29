#!perl -w
# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::TestCommon;
use PublicInbox::Import;
require_git(2.6);
require_mods(qw(DBD::SQLite Search::Xapian));
have_xapian_compact or
	plan skip_all => 'xapian-compact missing for '.__FILE__;
my ($tmpdir, $for_destroy) = tmpdir();
my $ibx = create_inbox 'v1', indexlevel => 'medium', tmpdir => "$tmpdir/v1",
		pre_cb => sub {
			my ($inboxdir) = @_;
			PublicInbox::Import::init_bare($inboxdir);
			xsys_e(qw(git) , "--git-dir=$inboxdir",
				qw(config core.sharedRepository 0644));
		}, sub {
	my ($im, $ibx) = @_;
	$im->done;
	umask(077) or BAIL_OUT "umask: $!";
	$_[0] = $im = $ibx->importer(0);
	my $eml = PublicInbox::Eml->new(<<'EOF');
From: a@example.com
To: b@example.com
Subject: this is a subject
Message-ID: <a-mid@b>
Date: Fri, 02 Oct 1993 00:00:00 +0000

hello world
EOF
	$im->add($eml) or BAIL_OUT '->add';
	$im->remove($eml) or BAIL_OUT '->remove';
	$im->add($eml) or BAIL_OUT '->add';
};
umask(077) or BAIL_OUT "umask: $!";
is(((stat("$ibx->{inboxdir}/public-inbox"))[2]) & 07777, 0755,
	'sharedRepository respected for v1');
is(((stat("$ibx->{inboxdir}/public-inbox/msgmap.sqlite3"))[2]) & 07777, 0644,
	'sharedRepository respected for v1 msgmap');
my @xdir = glob("$ibx->{inboxdir}/public-inbox/xap*/*");
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0644 : 0755,
		'sharedRepository respected on file after convert');
}

local $ENV{PI_CONFIG} = '/dev/null';
my ($out, $err) = ('', '');
my $rdr = { 1 => \$out, 2 => \$err };

my $cmd = [ '-compact', $ibx->{inboxdir} ];
ok(run_script($cmd, undef, $rdr), 'v1 compact works');

@xdir = glob("$ibx->{inboxdir}/public-inbox/xap*");
is(scalar(@xdir), 1, 'got one xapian directory after compact');
is(((stat($xdir[0]))[2]) & 07777, 0755,
	'sharedRepository respected on v1 compact');

my $hwm = do {
	my $mm = $ibx->mm;
	$ibx->cleanup;
	$mm->num_highwater;
};
ok(defined($hwm) && $hwm > 0, "highwater mark set #$hwm");

$cmd = [ '-convert', '--no-index', $ibx->{inboxdir}, "$tmpdir/no-index" ];
ok(run_script($cmd, undef, $rdr), 'convert --no-index works');

$cmd = [ '-convert', $ibx->{inboxdir}, "$tmpdir/x/v2" ];
ok(run_script($cmd, undef, $rdr), 'convert works');
@xdir = glob("$tmpdir/x/v2/xap*/*");
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0644 : 0755,
		'sharedRepository respected after convert');
}

$cmd = [ '-compact', "$tmpdir/x/v2" ];
my $env = { NPROC => 2 };
ok(run_script($cmd, $env, $rdr), 'v2 compact works');
$ibx->{inboxdir} = "$tmpdir/x/v2";
$ibx->{version} = 2;
is($ibx->mm->num_highwater, $hwm, 'highwater mark unchanged in v2 inbox');

@xdir = glob("$tmpdir/x/v2/xap*/*");
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0644 : 0755,
		'sharedRepository respected after v2 compact');
}
is(((stat("$tmpdir/x/v2/msgmap.sqlite3"))[2]) & 07777, 0644,
	'sharedRepository respected for v2 msgmap');

@xdir = (glob("$tmpdir/x/v2/git/*.git/objects/*/*"),
	 glob("$tmpdir/x/v2/git/*.git/objects/pack/*"));
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0444 : 0755,
		'sharedRepository respected after v2 compact');
}
my $msgs = $ibx->over->recent({limit => 1000});
is($msgs->[0]->{mid}, 'a-mid@b', 'message exists in history');
is(scalar @$msgs, 1, 'only one message in history');

$ibx = undef;
$err = '';
$cmd = [ qw(-index -j0 --reindex -c), "$tmpdir/x/v2" ];
ok(run_script($cmd, undef, $rdr), '--reindex -c');
like($err, qr/xapian-compact/, 'xapian-compact ran (-c)');

$rdr->{2} = \(my $err2 = '');
$cmd = [ qw(-index -j0 --reindex -cc), "$tmpdir/x/v2" ];
ok(run_script($cmd, undef, $rdr), '--reindex -c -c');
like($err2, qr/xapian-compact/, 'xapian-compact ran (-c -c)');
ok(($err2 =~ tr/\n/\n/) > ($err =~ tr/\n/\n/), '-compacted twice');

done_testing();
