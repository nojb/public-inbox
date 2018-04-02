# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::OverIdxFork;
use strict;
use warnings;
use base qw(PublicInbox::OverIdx PublicInbox::Lock);
use Storable qw(freeze thaw);
use IO::Handle;

sub create {
	my ($self, $v2writable) = @_;
	$self->SUPER::create();
	$self->spawn_worker($v2writable) if $v2writable->{parallel};
}

sub spawn_worker {
	my ($self, $v2writable) = @_;
	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
	my ($barrier_wait, $barrier_note);
	pipe($barrier_wait, $barrier_note) or die "pipe failed: $!\n";
	binmode $_, ':raw' foreach ($r, $w, $barrier_wait, $barrier_note);
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		$v2writable->atfork_child;
		$v2writable = undef;
		close $w;
		close $barrier_wait;

		# F_SETPIPE_SZ = 1031 on Linux; increasing the pipe size here
		# speeds V2Writable batch imports across 8 cores by nearly 20%
		fcntl($r, 1031, 1048576) if $^O eq 'linux';

		eval { over_worker_loop($self, $r, $barrier_note) };
		die "over worker died: $@\n" if $@;
		exit;
	}
	$self->{w} = $w;
	$self->{pid} = $pid;
	$self->{lock_path} = "$self->{filename}.pipe.lock";
	close $r;
	close $barrier_note;
	$self->{barrier_wait} = $barrier_wait;
	$w->autoflush(1);
}

sub over_worker_loop {
	my ($self, $r, $barrier_note) = @_;
	$barrier_note->autoflush(1);
	$0 = 'pi-v2-overview';
	$self->begin_lazy;
	my $barrier = undef;
	while (my $line = $r->getline) {
		if ($line eq "commit\n") {
			$self->commit_lazy;
		} elsif ($line eq "close\n") {
			$self->disconnect;
		} elsif ($line =~ /\Abarrier_init (\d+)\n\z/) {
			my $n = $1 - 1;
			die "barrier in-progress\n" if defined $barrier;
			$barrier = { map { $_ => 1 } (0..$n) };
		} elsif ($line =~ /\Abarrier (\d+)\n\z/) {
			my $part = $1;
			die "no barrier in-progress\n" unless defined $barrier;
			delete $barrier->{$1} or die "unknown barrier: $part\n";
			if ((scalar keys %$barrier) == 0) {
				$barrier = undef;
				$self->commit_lazy;
				print $barrier_note "barrier_done\n" or die
					"print failed to barrier note: $!";
			}
		} elsif ($line =~ /\AD ([a-f0-9]{40,}) (.*)\n\z/s) {
			my ($oid, $mid) = ($1, $2);
			$self->remove_oid($oid, $mid);
		} else {
			my $len = int($line);
			my $n = read($r, my $msg, $len) or die "read: $!\n";
			$n == $len or die "short read: $n != $len\n";
			$msg = thaw($msg); # should raise on error
			defined $msg or die "failed to thaw buffer\n";
			eval { add_over($self, $msg) };
			warn "failed to index message <$msg->[-1]>: $@\n" if $@;
		}
	}
	die "$$ $0 dbh not released\n" if $self->{dbh};
	die "$$ $0 still in transaction\n" if $self->{txn};
}

# called by a partition worker
# values: [ DS, NUM, BYTES, LINES, TS, MIDS, XPATH, doc_data ]
sub add_over {
	my ($self, $values) = @_;
	if (my $w = $self->{w}) {
		my $err;
		my $str = freeze($values);
		$str = length($str) . "\n" . $str;

		# multiple processes write to the same pipe, so use flock
		# We can't avoid this lock for <=PIPE_BUF writes, either,
		# because those atomic writes can break up >PIPE_BUF ones
		$self->lock_acquire;
		print $w $str or $err = $!;
		$self->lock_release;

		die "print failed: $err\n" if $err;
	} else {
		$self->SUPER::add_over($values);
	}
}

sub remove_oid {
	my ($self, $oid, $mid) = @_;
	if (my $w = $self->{w}) {
		my $err;
		$self->lock_acquire;
		print $w "D $oid $mid\n" or $err = $!;
		$self->lock_release;
		die $err if $err;
	} else {
		$self->SUPER::remove_oid($oid, $mid); # OverIdx
	}
}

# write to the subprocess
sub barrier_init {
	my ($self, $nparts) = @_;
	my $w = $self->{w} or return;
	my $err;
	$self->lock_acquire;
	print $w "barrier_init $nparts\n" or $err = $!;
	$self->lock_release;
	die $err if $err;
}

sub barrier_wait {
	my ($self) = @_;
	my $bw = $self->{barrier_wait} or return;
	my $l = $bw->getline;
	$l eq "barrier_done\n" or die "bad response from barrier_wait: $l\n";
}

sub remote_commit {
	my ($self) = @_;
	if (my $w = $self->{w}) {
		my $err;
		$self->lock_acquire;
		print $w "commit\n" or $err = $!;
		$self->lock_release;
		die $err if $err;
	} else {
		$self->commit_lazy;
	}
}

# prevent connections when using forked subprocesses
sub connect {
	my ($self) = @_;
	return if $self->{w};
	$self->SUPER::connect;
}

sub remote_close {
	my ($self) = @_;
	if (my $w = delete $self->{w}) {
		my $pid = delete $self->{pid} or die "no process to wait on\n";
		print $w "close\n" or die "failed to write to pid:$pid: $!\n";
		close $w or die "failed to close pipe for pid:$pid: $!\n";
		waitpid($pid, 0) == $pid or die "remote process did not finish";
		$? == 0 or die ref($self)." pid:$pid exited with: $?";
	} else {
		die "transaction in progress $self\n" if $self->{txn};
		$self->disconnect;
	}
}

sub commit_fsync {
	my ($self) = @_;
	return if $self->{w}; # don't bother; main parent can also call this
	$self->SUPER::commit_fsync;
}

1;
