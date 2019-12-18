# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::Admin', qw(resolve_repo_dir);
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/v1";
my $v2_dir = "$tmpdir/v2";
my ($res, $err, $v);

is(0, system(qw(git init -q --bare), $git_dir), 'git init v1');

# v1
is(resolve_repo_dir($git_dir), $git_dir, 'top-level GIT_DIR resolved');
is(resolve_repo_dir("$git_dir/objects"), $git_dir, 'GIT_DIR/objects resolved');

ok(chdir($git_dir), 'chdir GIT_DIR works');
is(resolve_repo_dir(), $git_dir, 'resolve_repo_dir works in GIT_DIR');

ok(chdir("$git_dir/objects"), 'chdir GIT_DIR/objects works');
is(resolve_repo_dir(), $git_dir, 'resolve_repo_dir works in GIT_DIR');
$res = resolve_repo_dir(undef, \$v);
is($v, 1, 'version 1 detected');
is($res, $git_dir, 'detects directory along with version');

# $tmpdir could be inside a git working, directory, so we test '/'
SKIP: {
	my $no_vcs_dir = '/';
	# do people version-control "/"?
	skip "$no_vcs_dir is version controlled by git", 4 if -d '/.git';
	open my $null, '>', '/dev/null' or die "open /dev/null: $!";
	open my $olderr, '>&', \*STDERR or die "dup stderr: $!";

	ok(chdir($no_vcs_dir), 'chdir to a non-inbox');
	open STDERR, '>&', $null or die "redirect stderr to /dev/null: $!";
	$res = eval { resolve_repo_dir() };
	open STDERR, '>&', $olderr or die "restore stderr: $!";
	is($res, undef, 'fails inside non-version-controlled dir');

	ok(chdir($tmpdir), 'back to test-specific $tmpdir');
	open STDERR, '>&', $null or die "redirect stderr to /dev/null: $!";
	$res = eval { resolve_repo_dir($no_vcs_dir) };
	$err = $@;
	open STDERR, '>&', $olderr or die "restore stderr: $!";
	is($res, undef, 'fails on non-version-controlled dir');
	ok($err, '$@ set on failure');
}

# v2
SKIP: {
	for my $m (qw(DBD::SQLite)) {
		skip "$m missing", 5 unless eval "require $m";
	}
	use_ok 'PublicInbox::V2Writable';
	use_ok 'PublicInbox::Inbox';
	my $ibx = PublicInbox::Inbox->new({
			inboxdir => $v2_dir,
			name => 'test-v2writable',
			version => 2,
			-primary_address => 'test@example.com',
			indexlevel => 'basic',
		});
	PublicInbox::V2Writable->new($ibx, 1)->idx_init;

	ok(-e "$v2_dir/inbox.lock", 'exists');
	is(resolve_repo_dir($v2_dir), $v2_dir,
		'resolve_repo_dir works on v2_dir');
	ok(chdir($v2_dir), 'chdir v2_dir OK');
	is(resolve_repo_dir(), $v2_dir, 'resolve_repo_dir works inside v2_dir');
	$res = resolve_repo_dir(undef, \$v);
	is($v, 2, 'version 2 detected');
	is($res, $v2_dir, 'detects directory along with version');

	# TODO: should work from inside Xapian dirs, and git dirs, here...
}

chdir '/';
done_testing();
