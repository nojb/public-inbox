# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Spawn qw(which spawn popen_rd);

{
	my $true = which('true');
	ok($true, "'true' command found with which()");
}

{
	my $pid = spawn(['true']);
	ok($pid, 'spawned process');
	is(waitpid($pid, 0), $pid, 'waitpid succeeds on spawned process');
	is($?, 0, 'true exited successfully');
}

{
	my ($r, $w);
	pipe $r, $w or die "pipe failed: $!";
	my $pid = spawn(['echo', 'hello world'], undef, { 1 => fileno($w) });
	close $w or die "close pipe[1] failed: $!";
	is(<$r>, "hello world\n", 'read stdout of spawned from pipe');
	is(waitpid($pid, 0), $pid, 'waitpid succeeds on spawned process');
	is($?, 0, 'true exited successfully');
}

{
	my ($r, $w);
	pipe $r, $w or die "pipe failed: $!";
	my $pid = spawn(['sh', '-c', 'echo $HELLO'],
		{ 'HELLO' => 'world' }, { 1 => fileno($w) });
	close $w or die "close pipe[1] failed: $!";
	is(<$r>, "world\n", 'read stdout of spawned from pipe');
	is(waitpid($pid, 0), $pid, 'waitpid succeeds on spawned process');
	is($?, 0, 'sh exited successfully');
}

{
	my ($r, $w);
	pipe $r, $w or die "pipe failed: $!";
	my $pid = spawn(['env'], {}, { -env => 1, 1 => fileno($w) });
	close $w or die "close pipe[1] failed: $!";
	ok(!defined(<$r>), 'read stdout of spawned from pipe');
	is(waitpid($pid, 0), $pid, 'waitpid succeeds on spawned process');
	is($?, 0, 'env(1) exited successfully');
}

{
	my $fh = popen_rd([qw(echo hello)]);
	ok(fileno($fh) >= 0, 'tied fileno works');
	my $l = <$fh>;
	is($l, "hello\n", 'tied readline works');
	$l = <$fh>;
	ok(!$l, 'tied readline works for EOF');
}

{
	my $fh = popen_rd([qw(printf foo\nbar)]);
	ok(fileno($fh) >= 0, 'tied fileno works');
	my @line = <$fh>;
	is_deeply(\@line, [ "foo\n", 'bar' ], 'wantarray works on readline');
}

{
	my $fh = popen_rd([qw(echo hello)]);
	my $buf;
	is(sysread($fh, $buf, 6), 6, 'sysread got 6 bytes');
	is($buf, "hello\n", 'tied gets works');
	is(sysread($fh, $buf, 6), 0, 'sysread got EOF');
}

{
	my ($fh, $pid) = popen_rd([qw(sleep 60)], undef, { Blocking => 0 });
	ok(defined $pid && $pid > 0, 'returned pid when array requested');
	is(kill(0, $pid), 1, 'child process is running');
	ok(!defined(sysread($fh, my $buf, 1)) && $!{EAGAIN},
	   'sysread returned quickly with EAGAIN');
	is(kill(15, $pid), 1, 'child process killed early');
	is(waitpid($pid, 0), $pid, 'child process reapable');
}

done_testing();

1;
