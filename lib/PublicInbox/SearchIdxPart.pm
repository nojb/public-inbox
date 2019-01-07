# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used to interface with a single Xapian partition in V2 repos.
# See L<public-inbox-v2-format(5)> for more info on how we partition Xapian
package PublicInbox::SearchIdxPart;
use strict;
use warnings;
use base qw(PublicInbox::SearchIdx);

sub new {
	my ($class, $v2writable, $part) = @_;
	my $self = $class->SUPER::new($v2writable->{-inbox}, 1, $part);
	# create the DB before forking:
	$self->_xdb_acquire;
	$self->_xdb_release;
	$self->spawn_worker($v2writable, $part) if $v2writable->{parallel};
	$self;
}

sub spawn_worker {
	my ($self, $v2writable, $part) = @_;
	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
	binmode $r, ':raw';
	binmode $w, ':raw';
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		my $bnote = $v2writable->atfork_child;
		$v2writable = undef;
		close $w or die "failed to close: $!";

		# F_SETPIPE_SZ = 1031 on Linux; increasing the pipe size here
		# speeds V2Writable batch imports across 8 cores by nearly 20%
		fcntl($r, 1031, 1048576) if $^O eq 'linux';

		eval { partition_worker_loop($self, $r, $part, $bnote) };
		die "worker $part died: $@\n" if $@;
		die "unexpected MM $self->{mm}" if $self->{mm};
		exit;
	}
	$self->{pid} = $pid;
	$self->{w} = $w;
	close $r or die "failed to close: $!";
}

sub partition_worker_loop ($$$$) {
	my ($self, $r, $part, $bnote) = @_;
	$0 = "pi-v2-partition[$part]";
	$self->begin_txn_lazy;
	while (my $line = $r->getline) {
		if ($line eq "commit\n") {
			$self->commit_txn_lazy;
		} elsif ($line eq "close\n") {
			$self->_xdb_release;
		} elsif ($line eq "barrier\n") {
			$self->commit_txn_lazy;
			# no need to lock < 512 bytes is atomic under POSIX
			print $bnote "barrier $part\n" or
					die "write failed for barrier $!\n";
		} elsif ($line =~ /\AD ([a-f0-9]{40,}) (.+)\n\z/s) {
			my ($oid, $mid) = ($1, $2);
			$self->begin_txn_lazy;
			$self->remove_by_oid($oid, $mid);
		} else {
			chomp $line;
			my ($len, $artnum, $oid, $mid0) = split(/ /, $line);
			$self->begin_txn_lazy;
			my $n = read($r, my $msg, $len) or die "read: $!\n";
			$n == $len or die "short read: $n != $len\n";
			my $mime = PublicInbox::MIME->new(\$msg);
			$artnum = int($artnum);
			$self->add_message($mime, $n, $artnum, $oid, $mid0);
		}
	}
	$self->worker_done;
}

# called by V2Writable
sub index_raw {
	my ($self, $bytes, $msgref, $artnum, $oid, $mid0, $mime) = @_;
	if (my $w = $self->{w}) {
		print $w "$bytes $artnum $oid $mid0\n", $$msgref or die
			"failed to write partition $!\n";
		$w->flush or die "failed to flush: $!\n";
	} else {
		$$msgref = undef;
		$self->begin_txn_lazy;
		$self->add_message($mime, $bytes, $artnum, $oid, $mid0);
	}
}

sub atfork_child {
	close $_[0]->{w} or die "failed to close write pipe: $!\n";
}

# called by V2Writable:
sub remote_barrier {
	my ($self) = @_;
	if (my $w = $self->{w}) {
		print $w "barrier\n" or die "failed to print: $!";
		$w->flush or die "failed to flush: $!";
	} else {
		$self->commit_txn_lazy;
	}
}

1;
