# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::SearchIdxPart;
use strict;
use warnings;
use base qw(PublicInbox::SearchIdx);

sub new {
	my ($class, $v2writable, $part, $skel) = @_;
	my $self = $class->SUPER::new($v2writable->{-inbox}, 1, $part);
	$self->{skeleton} = $skel;
	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
	binmode $r, ':raw';
	binmode $w, ':raw';
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		$v2writable->atfork_child;
		$v2writable = undef;
		close $w;

		# F_SETPIPE_SZ = 1031 on Linux; increasing the pipe size here
		# speeds V2Writable batch imports across 8 cores by nearly 20%
		fcntl($r, 1031, 1048576) if $^O eq 'linux';

		eval { partition_worker_loop($self, $r, $part) };
		die "worker $part died: $@\n" if $@;
		die "unexpected MM $self->{mm}" if $self->{mm};
		exit;
	}
	$self->{pid} = $pid;
	$self->{w} = $w;
	close $r;
	$self;
}

sub partition_worker_loop ($$$) {
	my ($self, $r, $part) = @_;
	$0 = "pi-v2-partition[$part]";
	my $xdb = $self->_xdb_acquire;
	$xdb->begin_transaction;
	my $txn = 1;
	while (my $line = $r->getline) {
		if ($line eq "commit\n") {
			$xdb->commit_transaction if $txn;
			$txn = undef;
		} elsif ($line eq "close\n") {
			$self->_xdb_release;
			$xdb = $txn = undef;
		} else {
			chomp $line;
			my ($len, $artnum, $object_id) = split(/ /, $line);
			$xdb ||= $self->_xdb_acquire;
			if (!$txn) {
				$xdb->begin_transaction;
				$txn = 1;
			}
			my $n = read($r, my $msg, $len) or die "read: $!\n";
			$n == $len or die "short read: $n != $len\n";
			my $mime = PublicInbox::MIME->new(\$msg);
			$artnum = int($artnum);
			$self->add_message($mime, $n, $artnum, $object_id);
		}
	}
	warn "$$ still in transaction\n" if $txn;
	warn "$$ xdb active\n" if $xdb;
}

# called by V2Writable
sub index_raw {
	my ($self, $len, $msgref, $artnum, $object_id) = @_;
	my $w = $self->{w};
	print $w "$len $artnum $object_id\n", $$msgref or die
		"failed to write partition $!\n";
	$w->flush or die "failed to flush: $!\n";
}

sub atfork_child {
	close $_[0]->{w} or die "failed to close write pipe: $!\n";
}

1;
