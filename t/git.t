# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
my $dir = tempdir('pi-git-XXXXXX', TMPDIR => 1, CLEANUP => 1);
use Cwd qw/getcwd/;
use PublicInbox::Spawn qw(popen_rd);

eval { require IPC::Run } or plan skip_all => 'IPC::Run missing';
use_ok 'PublicInbox::Git';

{
	is(system(qw(git init -q --bare), $dir), 0, 'created git directory');
	my $cmd = [ 'git', "--git-dir=$dir", 'fast-import', '--quiet' ];

	my $fi_data = getcwd().'/t/git.fast-import-data';
	ok(-r $fi_data, "fast-import data readable (or run test at top level)");
	IPC::Run::run($cmd, '<', $fi_data);
	is($?, 0, 'fast-import succeeded');
}

{
	my $gcf = PublicInbox::Git->new($dir);
	my $f = 'HEAD:foo.txt';
	my @x = $gcf->check($f);
	is(scalar @x, 3, 'returned 3 element array for existing file');
	like($x[0], qr/\A[a-f0-9]{40}\z/, 'returns obj ID in 1st element');
	is('blob', $x[1], 'returns obj type in 2nd element');
	like($x[2], qr/\A\d+\z/, 'returns obj size in 3rd element');

	my $raw = $gcf->cat_file($f);
	is($x[2], length($$raw), 'length matches');

	{
		my $size;
		my $rv = $gcf->cat_file($f, sub {
			my ($in, $left) = @_;
			$size = $$left;
			'nothing'
		});
		is($rv, 'nothing', 'returned from callback without reading');
		is($size, $x[2], 'set size for callback correctly');
	}

	eval { $gcf->cat_file($f, sub { die 'OMG' }) };
	like($@, qr/\bOMG\b/, 'died in callback propagated');
	is(${$gcf->cat_file($f)}, $$raw, 'not broken after failures');

	{
		my ($buf, $r);
		my $rv = $gcf->cat_file($f, sub {
			my ($in, $left) = @_;
			$r = read($in, $buf, 2);
			$$left -= $r;
			'blah'
		});
		is($r, 2, 'only read 2 bytes');
		is($buf, '--', 'partial read succeeded');
		is($rv, 'blah', 'return value propagated');
	}
	is(${$gcf->cat_file($f)}, $$raw, 'not broken after partial read');
}

if (1) {
	my $cmd = [ 'git', "--git-dir=$dir", qw(hash-object -w --stdin) ];

	# need a big file, use the AGPL-3.0 :p
	my $big_data = getcwd().'/COPYING';
	ok(-r $big_data, 'COPYING readable');
	my $size = -s $big_data;
	ok($size > 8192, 'file is big enough');

	my $buf = '';
	IPC::Run::run($cmd, '<', $big_data, '>', \$buf);
	is(0, $?, 'hashed object successfully');
	chomp $buf;

	my $gcf = PublicInbox::Git->new($dir);
	my $rsize;
	is($gcf->cat_file($buf, sub {
		$rsize = ${$_[1]};
		'x';
	}), 'x', 'checked input');
	is($rsize, $size, 'got correct size on big file');

	my $x = $gcf->cat_file($buf, \$rsize);
	is($rsize, $size, 'got correct size ref on big file');
	is(length($$x), $size, 'read correct number of bytes');

	my $rline;
	$gcf->cat_file($buf, sub {
		my ($in, $left) = @_;
		$rline = <$in>;
		$$left -= length($rline);
	});
	{
		open my $fh, '<', $big_data or die "open failed: $!\n";
		is($rline, <$fh>, 'first line matches');
	};

	my $all;
	$gcf->cat_file($buf, sub {
		my ($in, $left) = @_;
		my $x = read($in, $all, $$left);
		$$left -= $x;
	});
	{
		open my $fh, '<', $big_data or die "open failed: $!\n";
		local $/;
		is($all, <$fh>, 'entire read matches');
	};

	my $ref = $gcf->qx(qw(cat-file blob), $buf);
	is($all, $ref, 'qx read giant single string');

	my @ref = $gcf->qx(qw(cat-file blob), $buf);
	is($all, join('', @ref), 'qx returned array when wanted');
	my $nl = scalar @ref;
	ok($nl > 1, "qx returned array length of $nl");

	$gcf->qx(qw(repack -adq));
	ok($gcf->packed_bytes > 0, 'packed size is positive');
}

if ('alternates reloaded') {
	my $alt = tempdir('pi-git-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my @cmd = ('git', "--git-dir=$alt", qw(hash-object -w --stdin));
	is(system(qw(git init -q --bare), $alt), 0, 'create alt directory');
	open my $fh, '<', "$alt/config" or die "open failed: $!\n";
	my $rd = popen_rd(\@cmd, {}, { 0 => fileno($fh) } );
	close $fh or die "close failed: $!";
	chomp(my $remote = <$rd>);
	my $gcf = PublicInbox::Git->new($dir);
	is($gcf->cat_file($remote), undef, "remote file not found");
	open $fh, '>>', "$dir/objects/info/alternates" or
			die "open failed: $!\n";
	print $fh "$alt/objects" or die "print failed: $!\n";
	close $fh or die "close failed: $!";
	my $found = $gcf->cat_file($remote);
	open $fh, '<', "$alt/config" or die "open failed: $!\n";
	my $config = eval { local $/; <$fh> };
	is($$found, $config, 'alternates reloaded');
}

use_ok 'PublicInbox::Git', qw(git_unquote);
my $s;
is("foo\nbar", git_unquote($s = '"foo\\nbar"'), 'unquoted newline');
is("Eléanor", git_unquote($s = '"El\\303\\251anor"'), 'unquoted octal');
is(git_unquote($s = '"I\"m"'), 'I"m', 'unquoted dq');
is(git_unquote($s = '"I\\m"'), 'I\\m', 'unquoted backslash');

done_testing();
