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
use PublicInbox::V2Writable;
use PublicInbox::Import;
my $tmpdir = tempdir('convert-compact-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => "$tmpdir/v1",
	name => 'test-v1',
	-primary_address => 'test@example.com',
};

ok(PublicInbox::Import::run_die([qw(git init --bare -q), $ibx->{mainrepo}]),
	'initialized v1 repo');
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
$im->done;
PublicInbox::SearchIdx->new($ibx, 1)->index_sync;
local $ENV{PATH} = "blib/script:$ENV{PATH}";
open my $err, '>>', "$tmpdir/err.log" or die "open: err.log $!\n";
open my $out, '>>', "$tmpdir/out.log" or die "open: out.log $!\n";
my $rdr = { 1 => fileno($out), 2 => fileno($err) };

my $cmd = [ 'public-inbox-compact', $ibx->{mainrepo} ];
ok(PublicInbox::Import::run_die($cmd, undef, $rdr), 'v1 compact works');

$cmd = [ 'public-inbox-convert', $ibx->{mainrepo}, "$tmpdir/v2" ];
ok(PublicInbox::Import::run_die($cmd, undef, $rdr), 'convert works');

$cmd = [ 'public-inbox-compact', "$tmpdir/v2" ];
my $env = { NPROC => 2 };
ok(PublicInbox::Import::run_die($cmd, $env, $rdr), 'v2 compact works');
$ibx->{mainrepo} = "$tmpdir/v2";
my $v2w = PublicInbox::V2Writable->new($ibx);
is($v2w->{partitions}, 1, "only one partition in compacted repo");

done_testing();
