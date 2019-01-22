# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
require './t/common.perl';
require_git(2.6);

my @mods = qw(DBD::SQLite Search::Xapian HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for $0" if $@;
}
chomp(my $git_dir = `git rev-parse --git-dir 2>/dev/null`);
plan skip_all => "$0 must be run from a git working tree" if $?;
$git_dir = abs_path($git_dir);

use_ok "PublicInbox::$_" for (qw(Inbox V2Writable MIME Git SolverGit));

my $mainrepo = tempdir('pi-solver-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $opts = {
	mainrepo => $mainrepo,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
my $ibx = PublicInbox::Inbox->new($opts);
my $im = PublicInbox::V2Writable->new($ibx, 1);
$im->{parallel} = 0;

sub deliver_patch ($) {
	open my $fh, '<', $_[0] or die "open: $!";
	my $mime = PublicInbox::MIME->new(do { local $/; <$fh> });
	$im->add($mime);
	$im->done;
}

deliver_patch('t/solve/0001-simple-mod.patch');

$ibx->{-repo_objs} = [ PublicInbox::Git->new($git_dir) ];
my $res;
my $solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
open my $log, '+>>', "$mainrepo/solve.log" or die "open: $!";
my $psgi_env = { 'psgi.url_scheme' => 'http', HTTP_HOST => 'example.com' };
$solver->solve($psgi_env, $log, '69df7d5', {});
ok($res, 'solved a blob!');
my $wt_git = $res->[0];
is(ref($wt_git), 'PublicInbox::Git', 'got a git object for the blob');
my $expect = '69df7d565d49fbaaeb0a067910f03dc22cd52bd0';
is($res->[1], $expect, 'resolved blob to unabbreviated identifier');
is($res->[2], 'blob', 'type specified');
is($res->[3], 4405, 'size returned');

is(ref($wt_git->cat_file($res->[1])), 'SCALAR', 'wt cat-file works');
is_deeply([$expect, 'blob', 4405],
	  [$wt_git->check($res->[1])], 'wt check works');

if (0) { # TODO: check this?
	seek($log, 0, 0);
	my $z = do { local $/; <$log> };
	diag $z;
}

$solver = undef;
$res = undef;
my $wt_git_dir = $wt_git->{git_dir};
$wt_git = undef;
ok(!-d $wt_git_dir, 'no references to WT held');

$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, '0'x40, {});
is($res, undef, 'no error on z40');

my $git_v2_20_1_tag = '7a95a1cd084cb665c5c2586a415e42df0213af74';
$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, $git_v2_20_1_tag, {});
is($res, undef, 'no error on a tag not in our repo');

deliver_patch('t/solve/0002-rename-with-modifications.patch');
$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, '0a92431', {});
ok($res, 'resolved without hints');

my $hints = {
	oid_a => '3435775',
	path_a => 'HACKING',
	path_b => 'CONTRIBUTING'
};
$solver = PublicInbox::SolverGit->new($ibx, sub { $res = $_[0] });
$solver->solve($psgi_env, $log, '0a92431', $hints);
my $hinted = $res;
# don't compare ::Git objects:
shift @$res; shift @$hinted;
is_deeply($res, $hinted, 'hints work (or did not hurt :P');

done_testing();
