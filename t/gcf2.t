#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use PublicInbox::TestCommon;
use Test::More;
use Fcntl qw(:seek);
use IO::Handle ();
use POSIX qw(_exit);
use Cwd qw(abs_path);
require_mods('PublicInbox::Gcf2');
use_ok 'PublicInbox::Gcf2';
use PublicInbox::Import;
my ($tmpdir, $for_destroy) = tmpdir();

my $gcf2 = PublicInbox::Gcf2::new();
is(ref($gcf2), 'PublicInbox::Gcf2', '::new works');
my $COPYING = 'dba13ed2ddf783ee8118c6a581dbf75305f816a3';
open my $agpl, '<', 'COPYING' or BAIL_OUT "AGPL-3 missing: $!";
$agpl = do { local $/; <$agpl> };

PublicInbox::Import::init_bare($tmpdir);
my $fi_data = './t/git.fast-import-data';
my $rdr = {};
open $rdr->{0}, '<', $fi_data or BAIL_OUT $!;
xsys([qw(git fast-import --quiet)], { GIT_DIR => $tmpdir }, $rdr);
is($?, 0, 'fast-import succeeded');
$gcf2->add_alternate("$tmpdir/objects");

{
	my ($r, $w);
	pipe($r, $w) or BAIL_OUT $!;
	my $tree = 'fdbc43725f21f485051c17463b50185f4c3cf88c';
	$gcf2->cat_oid(fileno($w), $tree);
	close $w;
	is("$tree tree 30\n", <$r>, 'tree header ok');
	$r = do { local $/; <$r> };
	is(chop($r), "\n", 'got trailing newline');
	is(length($r), 30, 'tree length matches');
}

chomp(my $objdir = xqx([qw(git rev-parse --git-path objects)]));
if ($objdir =~ /\A--git-path\n/) { # git <2.5
	chomp($objdir = xqx([qw(git rev-parse --git-dir)]));
	$objdir .= '/objects';
}
if ($objdir && -d $objdir) {
	$objdir = abs_path($objdir);
	open my $alt, '>>', "$tmpdir/objects/info/alternates" or
							BAIL_OUT $!;
	print $alt $objdir, "\n" or BAIL_OUT $!;
	close $alt or BAIL_OUT $!;

	# calling gcf2->add_alternate on an already-added path won't
	# cause alternates to be reloaded, so we do
	# $gcf2->add_alternate($objdir) later on instead of
	# $gcf2->add_alternate("$tmpdir/objects");
	# $objdir = "$tmpdir/objects";
} else {
	$objdir = undef
}

my $nr = $ENV{TEST_LEAK_NR};
my $cat = $ENV{TEST_LEAK_CAT} // 10;
diag "checking for leaks... (TEST_LEAK_NR=$nr TEST_LEAK_CAT=$cat)" if $nr;

SKIP: {
	skip 'not in git worktree', 21 unless defined($objdir);
	$gcf2->add_alternate($objdir);
	eval { $gcf2->add_alternate($objdir) };
	ok(!$@, 'no error adding alternate redundantly');
	if ($nr) {
		diag "adding alternate $nr times redundantly";
		$gcf2->add_alternate($objdir) for (1..$nr);
		diag 'done adding redundant alternates';
	}

	open my $fh, '+>', undef or BAIL_OUT "open: $!";
	my $fd = fileno($fh);
	$fh->autoflush(1);

	$gcf2->cat_oid($fd, 'invalid');
	seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
	is(do { local $/; <$fh> }, "invalid missing\n", 'got missing message');

	seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
	$gcf2->cat_oid($fd, '0'x40);
	seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
	is(do { local $/; <$fh> }, ('0'x40)." missing\n",
		'got missing message for 0x40');

	seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
	$gcf2->cat_oid($fd, $COPYING);
	my $buf;
	my $ck_copying = sub {
		my ($desc) = @_;
		seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
		is(<$fh>, "$COPYING blob 34520\n", 'got expected header');
		$buf = do { local $/; <$fh> };
		is(chop($buf), "\n", 'got trailing \\n');
		is($buf, $agpl, "AGPL matches ($desc)");
	};
	$ck_copying->('regular file');

	$gcf2 = PublicInbox::Gcf2::new();
	$gcf2->add_alternate("$tmpdir/objects");
	$ck_copying->('alternates respected');

	$^O eq 'linux' or skip('pipe tests are Linux-only', 12);
	my $size = -s $fh;
	for my $blk (1, 0) {
		my ($r, $w);
		pipe($r, $w) or BAIL_OUT $!;
		fcntl($w, 1031, 4096) or
			skip('Linux too old for F_SETPIPE_SZ', 12);
		$w->blocking($blk);
		seek($fh, 0, SEEK_SET) or BAIL_OUT "seek: $!";
		truncate($fh, 0) or BAIL_OUT "truncate: $!";
		defined(my $pid = fork) or BAIL_OUT "fork: $!";
		if ($pid == 0) {
			close $w;
			tick; # wait for parent to block on writev
			$buf = do { local $/; <$r> };
			print $fh $buf or _exit(1);
			_exit(0);
		}
		$gcf2->cat_oid(fileno($w), $COPYING);
		close $w or BAIL_OUT "close: $!";
		is(waitpid($pid, 0), $pid, 'child exited');
		is($?, 0, 'no error in child');
		$ck_copying->("pipe blocking($blk)");

		pipe($r, $w) or BAIL_OUT $!;
		fcntl($w, 1031, 4096) or BAIL_OUT $!;
		$w->blocking($blk);
		close $r;
		local $SIG{PIPE} = 'IGNORE';
		eval { $gcf2->cat_oid(fileno($w), $COPYING) };
		like($@, qr/writev error:/, 'got writev error');
	}
}

if ($nr) {
	open my $null, '>', '/dev/null' or BAIL_OUT "open /dev/null: $!";
	my $fd = fileno($null);
	local $SIG{PIPE} = 'IGNORE';
	my ($r, $w);
	pipe($r, $w);
	close $r;
	my $broken = fileno($w);
	for (1..$nr) {
		my $obj = PublicInbox::Gcf2::new();
		if (defined($objdir)) {
			$obj->add_alternate($objdir);
			for (1..$cat) {
				$obj->cat_oid($fd, $COPYING);
				eval { $obj->cat_oid($broken, $COPYING) };
				$obj->cat_oid($fd, '0'x40);
				$obj->cat_oid($fd, 'invalid');
			}
		}
	}
}
done_testing;
