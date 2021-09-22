#!/usr/bin/perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
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
use v5.10.1;
use IO::Handle; # ->autoflush
use PublicInbox::TestCommon;
use PublicInbox::Spawn;
use Getopt::Long qw(:config gnu_getopt no_ignore_case auto_abbrev);
use Errno qw(EINTR);
use Fcntl qw(:seek);
use POSIX qw(WNOHANG);
use File::Temp ();
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
if (($ENV{TEST_RUN_MODE} // 2) == 0) {
	die "$0 is not compatible with TEST_RUN_MODE=0\n";
}
my @tests = scalar(@ARGV) ? @ARGV : glob('t/*.t');
open my $cwd_fh, '<', '.' or die "open .: $!";
open my $OLDOUT, '>&STDOUT' or die "dup STDOUT: $!";
open my $OLDERR, '>&STDERR' or die "dup STDERR: $!";
$OLDOUT->autoflush(1);
$OLDERR->autoflush(1);

my ($run_log, $tmp_rl);
my $rl = $ENV{TEST_RUN_LOG};
unless ($rl) {
	$tmp_rl = File::Temp->new(CLEANUP => 1);
	$rl = $tmp_rl->filename;
}
open $run_log, '+>>', $rl or die "open $rl: $!";
$run_log->autoflush(1); # one reader, many writers

key2sub($_) for @tests; # precache

my ($for_destroy, $lei_env, $lei_daemon_pid, $owner_pid);

# TEST_LEI_DAEMON_PERSIST is currently broken.  I get ECONNRESET from
# lei even with high kern.ipc.soacceptqueue=1073741823 or SOMAXCONN, not
# sure why.  Also, testing our internal inotify usage is unreliable
# because lei-daemon uses a single inotify FD for all clients.
if ($ENV{TEST_LEI_DAEMON_PERSIST} && !$ENV{TEST_LEI_DAEMON_PERSIST_DIR} &&
		(PublicInbox::Spawn->can('recv_cmd4') ||
			eval { require Socket::MsgHdr })) {
	$lei_env = {};
	($lei_env->{XDG_RUNTIME_DIR}, $for_destroy) = tmpdir;
	$ENV{TEST_LEI_DAEMON_PERSIST_DIR} = $lei_env->{XDG_RUNTIME_DIR};
	run_script([qw(lei daemon-pid)], $lei_env, { 1 => \$lei_daemon_pid });
	chomp $lei_daemon_pid;
	$lei_daemon_pid =~ /\A[0-9]+\z/ or die "no daemon pid: $lei_daemon_pid";
	kill(0, $lei_daemon_pid) or die "kill $lei_daemon_pid: $!";
	if (my $t = $ENV{GNU_TAIL}) {
		system("$t --pid=$lei_daemon_pid -F " .
			"$lei_env->{XDG_RUNTIME_DIR}/lei/errors.log >&2 &");
	}
	if (my $strace_cmd = $ENV{STRACE_CMD}) {
		system("$strace_cmd -p $lei_daemon_pid &");
	}
	$owner_pid = $$;
}

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
	print $OLDERR @_;
	exit(1);
}

our ($worker, $worker_test);

sub test_status () {
	$? = 255 if $? == 0 && !$tb->is_passing;
	my $status = $? ? 'not ok' : 'ok';
	chdir($cwd_fh) or DIE "fchdir: $!";
	if ($log_suffix ne '') {
		my $log = $worker_test;
		$log =~ s/\.t\z/$log_suffix/;
		my $skip = '';
		if (open my $fh, '<', $log) {
			my @not_ok = grep(!/^(?:ok |[ \t]*#)/ms, <$fh>);
			my $last = $not_ok[-1] // '';
			pop @not_ok if $last =~ /^[0-9]+\.\.[0-9]+$/;
			my $pfx = "# $log: ";
			print $OLDERR map { $pfx.$_ } @not_ok;
			seek($fh, 0, SEEK_SET) or die "seek: $!";

			# show unique skip texts and the number of times
			# each text was skipped
			local $/;
			my @sk = (<$fh> =~ m/^ok [0-9]+ (# skip [^\n]+)/mgs);
			if (@sk) {
				my %nr;
				my @err = grep { !$nr{$_}++ } @sk;
				print $OLDERR "$pfx$_ ($nr{$_})\n" for @err;
				$skip = ' # total skipped: '.scalar(@sk);
			}
		} else {
			print $OLDERR "could not open: $log: $!\n";
		}
		print $OLDOUT "$status $worker_test$skip\n";
	}
}

# Test::Builder or Test2::Hub may call exit() from plan(skip_all => ...)
END { test_status() if (defined($worker_test) && $worker == $$) }

sub run_test ($) {
	my ($test) = @_;
	syswrite($run_log, "$$ $test\n");
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
	my ($j, $rd, $wr, $todo) = @_;
	my $pid = fork // DIE "fork: $!";
	if ($pid == 0) {
		close $wr if $wr;
		$SIG{USR1} = undef; # undo parent $SIG{USR1}
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

	# single-producer, multi-consumer queue relying on POSIX pipe semantics
	# POSIX.1-2008 stipulates a regular file should work, but Linux <3.14
	# had broken read(2) semantics according to the read(2) manpage
	pipe(my ($rd, $wr)) or DIE "pipe: $!";

	# fill the queue before forking so children can start earlier
	my $n = (POSIX::PIPE_BUF / UINT_SIZE);
	if ($n >= $#todo) {
		print $wr join('', map { pack('I', $_) } (0..$#todo)) or DIE;
		undef $wr;
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
			if ($?) {
				seek($run_log, 0, SEEK_SET);
				chomp(my @t = grep(/^$pid /, <$run_log>));
				$t[0] //= "$pid unknown";
				push @err, "job[$j] ($?) PID=$t[-1]";
			}
			# skip_all can exit(0), respawn if needed:
			if (!$eof) {
				print $OLDERR "# respawning job[$j]\n";
				$start_worker->($j, $rd, $wr, \@todo);
			}
		}
	};

	# start the workers to consume the queue
	for (my $j = 0; $j < $jobs; $j++) {
		$start_worker->($j, $rd, $wr, \@todo);
	}
	if ($wr) {
		local $SIG{CHLD} = $sigchld;
		# too many tests to fit in the pipe before starting workers,
		# send the rest now the workers are running
		print $wr join('', map { pack('I', $_) } ($n..$#todo)) or DIE;
		undef $wr;
	}

	$sigchld->(0) while scalar(keys(%pids));
	DIE join('', map { "E: $_\n" } @err) if @err;
}

print $OLDOUT "1..".($repeat * scalar(@tests))."\n" if $repeat >= 0;
if ($lei_env && $$ == $owner_pid) {
	my $opt = { 1 => $OLDOUT, 2 => $OLDERR };
	my $cur_daemon_pid;
	run_script([qw(lei daemon-pid)], $lei_env, { 1 => \$cur_daemon_pid });
	run_script([qw(lei daemon-kill)], $lei_env, $opt);
	DIE "lei daemon restarted\n" if $cur_daemon_pid != $lei_daemon_pid;
}
