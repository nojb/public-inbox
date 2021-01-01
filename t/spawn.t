# Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Spawn qw(which spawn popen_rd);
use PublicInbox::Sigfd;

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

{ # ensure waitpid(-1, 0) and SIGCHLD works in spawned process
	my $script = <<'EOF';
$| = 1; # unbuffer stdout
defined(my $pid = fork) or die "fork: $!";
if ($pid == 0) { exit }
elsif ($pid > 0) {
	my $waited = waitpid(-1, 0);
	$waited == $pid or die "mismatched child $pid != $waited";
	$? == 0 or die "child err: $>";
	$SIG{CHLD} = sub { print "HI\n"; exit };
	print "RDY $$\n";
	select(undef, undef, undef, 0.01) while 1;
}
EOF
	my $oldset = PublicInbox::Sigfd::block_signals();
	my $rd = popen_rd([$^X, '-e', $script]);
	diag 'waiting for child to reap grandchild...';
	chomp(my $line = readline($rd));
	my ($rdy, $pid) = split(' ', $line);
	is($rdy, 'RDY', 'got ready signal, waitpid(-1) works in child');
	ok(kill('CHLD', $pid), 'sent SIGCHLD to child');
	is(readline($rd), "HI\n", '$SIG{CHLD} works in child');
	ok(close $rd, 'popen_rd close works');
	PublicInbox::Sigfd::sig_setmask($oldset);
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
		{ 'HELLO' => 'world' }, { 1 => $w });
	close $w or die "close pipe[1] failed: $!";
	is(<$r>, "world\n", 'read stdout of spawned from pipe');
	is(waitpid($pid, 0), $pid, 'waitpid succeeds on spawned process');
	is($?, 0, 'sh exited successfully');
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
	$? = 1;
	ok(close($fh), 'close succeeds');
	is($?, 0, '$? set properly');
}

{
	my $fh = popen_rd([qw(false)]);
	ok(!close($fh), 'close fails on false');
	isnt($?, 0, '$? set properly: '.$?);
}

SKIP: {
	eval {
		require BSD::Resource;
		defined(BSD::Resource::RLIMIT_CPU())
	} or skip 'BSD::Resource::RLIMIT_CPU missing', 3;
	my ($r, $w);
	pipe($r, $w) or die "pipe: $!";
	my $cmd = ['sh', '-c', 'while true; do :; done'];
	my $fd = fileno($w);
	my $opt = { RLIMIT_CPU => [ 1, 1 ], RLIMIT_CORE => [ 0, 0 ], 1 => $fd };
	my $pid = spawn($cmd, undef, $opt);
	close $w or die "close(w): $!";
	my $rset = '';
	vec($rset, fileno($r), 1) = 1;
	ok(select($rset, undef, undef, 5), 'child died before timeout');
	is(waitpid($pid, 0), $pid, 'XCPU child process reaped');
	isnt($?, 0, 'non-zero exit status');
}

done_testing();

1;
