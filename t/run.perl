#!/usr/bin/perl -w
# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Parallel test runner which preloads code and reuses worker processes
# to give a nice speedup over prove(1).  It also generates per-test
# .log files (similar to automake tests).
#
# *.t files run by this should not rely on global state.
#
# Usage: $PERL -I lib -w t/run.perl -j4
# Or via prove(1): prove -lvw t/run.perl :: -j4
use strict;
use PublicInbox::TestCommon;
use Cwd qw(getcwd);
use Getopt::Long qw(:config gnu_getopt no_ignore_case auto_abbrev);
use Errno qw(EINTR);
use POSIX qw(_POSIX_PIPE_BUF WNOHANG);
my $jobs = 1;
my $repeat = 1;
$| = 1;
our $log_suffix = '.log';
my ($shuffle, %pids, @err);
GetOptions('j|jobs=i' => \$jobs,
	'repeat=i' => \$repeat,
	'log=s' => \$log_suffix,
	's|shuffle' => \$shuffle,
) or die "Usage: $0 [-j JOBS] [--log=SUFFIX] [--repeat RUNS]";
if (($ENV{TEST_RUN_MODE} // 1) == 0) {
	die "$0 is not compatible with TEST_RUN_MODE=0\n";
}
my @tests = scalar(@ARGV) ? @ARGV : glob('t/*.t');
my $cwd = getcwd();
open OLDOUT, '>&STDOUT' or die "dup STDOUT: $!";
open OLDERR, '>&STDERR' or die "dup STDERR: $!";
OLDOUT->autoflush(1);
OLDERR->autoflush(1);

key2sub($_) for @tests; # precache

if ($shuffle) {
	require List::Util;
} elsif (open(my $prove_state, '<', '.prove') && eval { require YAML::XS }) {
	# reuse "prove --state=save" data to start slowest tests, first
	my $state = YAML::XS::Load(do { local $/; <$prove_state> });
	my $t = $state->{tests};
	@tests = sort {
		($t->{$b}->{elapsed} // 0) <=> ($t->{$a}->{elapsed} // 0)
	} @tests;
}

our $tb = Test::More->builder;

sub DIE (;$) {
	print OLDERR @_;
	exit(1);
}

our ($worker, $worker_test);

sub test_status () {
	$? = 255 if $? == 0 && !$tb->is_passing;
	my $status = $? ? 'not ok' : 'ok';
	print OLDOUT "$status $worker_test\n" if $log_suffix ne '';
}

# Test::Builder or Test2::Hub may call exit() from plan(skip_all => ...)
END { test_status() if (defined($worker_test) && $worker == $$) }

sub run_test ($) {
	my ($test) = @_;
	my $log_fh;
	if ($log_suffix ne '') {
		my $log = $test;
		$log =~ s/\.[^\.]+\z/$log_suffix/ or DIE "can't log for $test";
		open $log_fh, '>', $log or DIE "open $log: $!";
		$log_fh->autoflush(1);
		$tb->output($log_fh);
		$tb->failure_output($log_fh);
		$tb->todo_output($log_fh);
		open STDOUT, '>&', $log_fh or DIE "1>$log: $!";
		open STDERR, '>&', $log_fh or DIE "2>$log: $!";
	}
	$worker_test = $test;
	run_script([$test]);
	test_status();
	$worker_test = undef;
	push @err, "$test ($?)" if $?;
}

sub UINT_SIZE () { 4 }

# worker processes will SIGUSR1 the producer process when it
# sees EOF on the pipe.  On FreeBSD 11.2 and Perl 5.30.0,
# sys/ioctl.ph gives the wrong value for FIONREAD().
my $producer = $$;
my $eof; # we stop respawning if true

my $start_worker = sub {
	my ($i, $j, $rd, $todo) = @_;
	defined(my $pid = fork) or DIE "fork: $!";
	if ($pid == 0) {
		$worker = $$;
		while (1) {
			my $r = sysread($rd, my $buf, UINT_SIZE);
			if (!defined($r)) {
				next if $! == EINTR;
				DIE "sysread: $!";
			}
			last if $r == 0;
			DIE "short read $r" if $r != UINT_SIZE;
			my $t = unpack('I', $buf);
			run_test($todo->[$t]);
			$tb->reset;
			chdir($cwd) or DIE "chdir: $!";
		}
		kill 'USR1', $producer if !$eof; # sets $eof in $producer
		DIE join('', map { "E: $_\n" } @err) if @err;
		exit(0);
	} else {
		$pids{$pid} = $j;
	}
};

# negative $repeat means loop forever:
for (my $i = $repeat; $i != 0; $i--) {
	my @todo = $shuffle ? List::Util::shuffle(@tests) : @tests;

	# single-producer, multi-consumer queue relying on POSIX semantics
	pipe(my ($rd, $wr)) or DIE "pipe: $!";

	# fill the queue before forking so children can start earlier
	my $n = (_POSIX_PIPE_BUF / UINT_SIZE);
	if ($n >= $#todo) {
		print $wr join('', map { pack('I', $_) } (0..$#todo)) or DIE;
		close $wr or die;
		$wr = undef;
	} else { # write what we can...
		$wr->autoflush(1);
		print $wr join('', map { pack('I', $_) } (0..$n)) or DIE;
		$n += 1; # and send more ($n..$#todo), later
	}
	$eof = undef;
	local $SIG{USR1} = sub { $eof = 1 };
	my $sigchld = sub {
		my ($sig) = @_;
		my $flags = $sig ? WNOHANG : 0;
		while (1) {
			my $pid = waitpid(-1, $flags) or return;
			return if $pid < 0;
			my $j = delete $pids{$pid};
			if (!defined($j)) {
				push @err, "reaped unknown $pid ($?)";
				next;
			}
			push @err, "job[$j] ($?)" if $?;
			# skip_all can exit(0), respawn if needed:
			if (!$eof) {
				print OLDERR "# respawning job[$j]\n";
				$start_worker->($i, $j, $rd, \@todo);
			}
		}
	};

	# start the workers to consume the queue
	for (my $j = 0; $j < $jobs; $j++) {
		$start_worker->($i, $j, $rd, \@todo);
	}

	if ($wr) {
		local $SIG{CHLD} = $sigchld;
		# too many tests to fit in the pipe before starting workers,
		# send the rest now the workers are running
		print $wr join('', map { pack('I', $_) } ($n..$#todo)) or DIE;
		close $wr or die;
	}

	$sigchld->(0) while scalar(keys(%pids));
	DIE join('', map { "E: $_\n" } @err) if @err;
}

print OLDOUT "1..".($repeat * scalar(@tests))."\n" if $repeat >= 0;
