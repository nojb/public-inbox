# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::SearchIdxSkeleton;
use strict;
use warnings;
use base qw(PublicInbox::SearchIdx);
use Storable qw(freeze thaw);

sub new {
	my ($class, $v2writable) = @_;
	my $self = $class->SUPER::new($v2writable->{-inbox}, 1, 'skel');
	# create the DB:
	$self->_xdb_acquire;
	$self->_xdb_release;
	$self->spawn_worker($v2writable) if $v2writable->{parallel};
	$self
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
		eval { skeleton_worker_loop($self, $r, $barrier_note) };
		die "skeleton worker died: $@\n" if $@;
		exit;
	}
	$self->{w} = $w;
	$self->{pid} = $pid;
	close $r;
	close $barrier_note;
	$self->{barrier_wait} = $barrier_wait;

	$w->autoflush(1);

	# lock on only exists in parent, not in worker
	$self->{lock_path} = $self->xdir . '/pi-v2-skeleton.lock';
}

sub skeleton_worker_loop {
	my ($self, $r, $barrier_note) = @_;
	$barrier_note->autoflush(1);
	$0 = 'pi-v2-skeleton';
	$self->begin_txn_lazy;
	my $barrier = undef;
	while (my $line = $r->getline) {
		if ($line eq "commit\n") {
			$self->commit_txn_lazy;
		} elsif ($line eq "close\n") {
			$self->_xdb_release;
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
				$self->commit_txn_lazy;
				print $barrier_note "barrier_done\n" or die
					"print failed to barrier note: $!";
			}
		} elsif ($line =~ /\AD ([a-f0-9]{40,}) (.*)\n\z/s) {
			my ($oid, $mid) = ($1, $2);
			$self->begin_txn_lazy;
			$self->remove_by_oid($oid, $mid);
		} else {
			my $len = int($line);
			my $n = read($r, my $msg, $len) or die "read: $!\n";
			$n == $len or die "short read: $n != $len\n";
			$msg = thaw($msg); # should raise on error
			defined $msg or die "failed to thaw buffer\n";
			$self->begin_txn_lazy;
			eval { index_skeleton_real($self, $msg) };
			warn "failed to index message <$msg->[-1]>: $@\n" if $@;
		}
	}
	$self->worker_done;
}

# called by a partition worker
sub index_skeleton {
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
		$self->begin_txn_lazy;
		index_skeleton_real($self, $values);
	}
}

sub remote_remove {
	my ($self, $oid, $mid) = @_;
	my $err;
	$self->lock_acquire;
	eval { $self->SUPER::remote_remove($oid, $mid) };
	$err = $@;
	$self->lock_release;
	die $err if $err;
}

# values: [ DS, NUM, BYTES, LINES, TS, MIDS, XPATH, doc_data ]
sub index_skeleton_real ($$) {
	my ($self, $values) = @_;
	my $doc_data = pop @$values;
	my $xpath = pop @$values;
	my $mids = pop @$values;
	my $smsg = PublicInbox::SearchMsg->new(undef);
	my $doc = $smsg->{doc};
	PublicInbox::SearchIdx::add_values($doc, $values);
	$doc->set_data($doc_data);
	$smsg->load_from_data($doc_data);
	my $num = $values->[PublicInbox::Search::NUM];
	my @refs = ($smsg->references =~ /<([^>]+)>/g);
	$self->link_and_save($doc, $mids, \@refs, $num, $xpath);
}

# write to the subprocess
sub barrier_init {
	my ($self, $nparts) = @_;
	my $w = $self->{w} or return;
	my $err;
	$self->lock_acquire;
	print $w "barrier_init $nparts\n" or $err = "failed to write: $!\n";
	$self->lock_release;
	die $err if $err;
}

sub barrier_wait {
	my ($self) = @_;
	my $bw = $self->{barrier_wait} or return;
	my $l = $bw->getline;
	$l eq "barrier_done\n" or die "bad response from barrier_wait: $l\n";
}

1;
