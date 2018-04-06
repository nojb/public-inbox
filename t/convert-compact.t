# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use PublicInbox::MIME;
my @mods = qw(DBD::SQLite Search::Xapian);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for convert-compact.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
use PublicInbox::Import;
my $tmpdir = tempdir('convert-compact-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => "$tmpdir/v1",
	name => 'test-v1',
	-primary_address => 'test@example.com',
};

ok(PublicInbox::Import::run_die([qw(git init --bare -q), $ibx->{mainrepo}]),
	'initialized v1 repo');
ok(umask(077), 'set restrictive umask');
ok(PublicInbox::Import::run_die([qw(git) , "--git-dir=$ibx->{mainrepo}",
	qw(config core.sharedRepository 0644)]), 'set sharedRepository');
$ibx = PublicInbox::Inbox->new($ibx);
my $im = PublicInbox::Import->new($ibx->git, undef, undef, $ibx);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		'Message-ID' => '<a-mid@b>',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);
ok($im->add($mime), 'added one message');
ok($im->remove($mime), 'remove message');
ok($im->add($mime), 'added message again');
$im->done;
PublicInbox::SearchIdx->new($ibx, 1)->index_sync;

is(((stat("$ibx->{mainrepo}/public-inbox"))[2]) & 07777, 0755,
	'sharedRepository respected for v1');
is(((stat("$ibx->{mainrepo}/public-inbox/msgmap.sqlite3"))[2]) & 07777, 0644,
	'sharedRepository respected for v1 msgmap');
my @xdir = glob("$ibx->{mainrepo}/public-inbox/xap*/*");
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0644 : 0755,
		'sharedRepository respected on file after convert');
}

local $ENV{PATH} = "blib/script:$ENV{PATH}";
open my $err, '>>', "$tmpdir/err.log" or die "open: err.log $!\n";
open my $out, '>>', "$tmpdir/out.log" or die "open: out.log $!\n";
my $rdr = { 1 => fileno($out), 2 => fileno($err) };

my $cmd = [ 'public-inbox-compact', $ibx->{mainrepo} ];
ok(PublicInbox::Import::run_die($cmd, undef, $rdr), 'v1 compact works');

@xdir = glob("$ibx->{mainrepo}/public-inbox/xap*");
is(scalar(@xdir), 1, 'got one xapian directory after compact');
is(((stat($xdir[0]))[2]) & 07777, 0755,
	'sharedRepository respected on v1 compact');

$cmd = [ 'public-inbox-convert', $ibx->{mainrepo}, "$tmpdir/v2" ];
ok(PublicInbox::Import::run_die($cmd, undef, $rdr), 'convert works');
@xdir = glob("$tmpdir/v2/xap*/*");
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0644 : 0755,
		'sharedRepository respected after convert');
}

$cmd = [ 'public-inbox-compact', "$tmpdir/v2" ];
my $env = { NPROC => 2 };
ok(PublicInbox::Import::run_die($cmd, $env, $rdr), 'v2 compact works');
$ibx->{mainrepo} = "$tmpdir/v2";
$ibx->{version} = 2;
my $v2w = PublicInbox::V2Writable->new($ibx);
is($v2w->{partitions}, 1, "only one partition in compacted repo");

@xdir = glob("$tmpdir/v2/xap*/*");
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0644 : 0755,
		'sharedRepository respected after v2 compact');
}
is(((stat("$tmpdir/v2/msgmap.sqlite3"))[2]) & 07777, 0644,
	'sharedRepository respected for v2 msgmap');

@xdir = (glob("$tmpdir/v2/git/*.git/objects/*/*"),
	 glob("$tmpdir/v2/git/*.git/objects/pack/*"));
foreach (@xdir) {
	my @st = stat($_);
	is($st[2] & 07777, -f _ ? 0444 : 0755,
		'sharedRepository respected after v2 compact');
}
my $msgs = $ibx->recent({limit => 1000});
is($msgs->[0]->{mid}, 'a-mid@b', 'message exists in history');
is(scalar @$msgs, 1, 'only one message in history');

done_testing();
