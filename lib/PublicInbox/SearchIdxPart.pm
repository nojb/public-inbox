# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::SearchIdxPart;
use strict;
use warnings;
use base qw(PublicInbox::SearchIdx);

sub new {
	my ($class, $v2writable, $part, $threader) = @_;
	my $self = $class->SUPER::new($v2writable->{-inbox}, 1, $part);
	$self->{threader} = $threader;
	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		foreach my $other (@{$v2writable->{idx_parts}}) {
			my $other_w = $other->{w} or next;
			close $other_w or die "close other failed: $!\n";
		}
		$v2writable = undef;
		close $w;
		eval { partition_worker_loop($self, $r) };
		die "worker $part died: $@\n" if $@;
		die "unexpected MM $self->{mm}" if $self->{mm};
		exit;
	}
	$self->{pid} = $pid;
	$self->{w} = $w;
	close $r;
	$self;
}

sub partition_worker_loop ($$) {
	my ($self, $r) = @_;
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
			my ($len, $artnum, $object_id) = split(/ /, $line);
			$xdb ||= $self->_xdb_acquire;
			if (!$txn) {
				$xdb->begin_transaction;
				$txn = 1;
			}
			my $n = read($r, my $msg, $len) or die "read: $!\n";
			$n == $len or die "short read: $n != $len\n";
			my $mime = PublicInbox::MIME->new(\$msg);
			$self->index_blob($mime, $len, $artnum, $object_id);
		}
	}
	warn "$$ still in transaction\n" if $txn;
	warn "$$ xdb active\n" if $xdb;
}

# called by V2Writable
sub index_raw {
	my ($self, $len, $msgref, $artnum, $object_id) = @_;
	print { $self->{w} } "$len $artnum $object_id\n", $$msgref or die
		"failed to write partition $!\n";
}

1;
