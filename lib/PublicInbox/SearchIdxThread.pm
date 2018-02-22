# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::SearchIdxThread;
use strict;
use warnings;
use base qw(PublicInbox::SearchIdx);
use Storable qw(freeze thaw);

sub new {
	my ($class, $v2ibx) = @_;
	my $self = $class->SUPER::new($v2ibx, 1, 'all');
	# create the DB:
	$self->_xdb_acquire;
	$self->_xdb_release;

	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
	binmode $r, ':raw';
	binmode $w, ':raw';
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		close $w;
		eval { thread_worker_loop($self, $r) };
		die "thread worker died: $@\n" if $@;
		exit;
	}
	$self->{w} = $w;
	$self->{pid} = $pid;
	close $r;

	$w->autoflush(1);

	# lock on only exists in parent, not in worker
	my $l = $self->{lock_path} = $self->xdir . '/thread.lock';
	open my $fh, '>>', $l or die "failed to create $l: $!\n";
	$self;
}

sub thread_worker_loop {
	my ($self, $r) = @_;
	my $msg;
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
			read($r, $msg, $line) or die "read failed: $!\n";
			$msg = thaw($msg); # should raise on error
			defined $msg or die "failed to thaw buffer\n";
			if (!$txn) {
				$xdb->begin_transaction;
				$txn = 1;
			}
			eval { $self->thread_msg_real(@$msg) };
			warn "failed to index message <$msg->[0]>: $@\n" if $@;
		}
	}
}

# called by a partition worker
sub thread_msg {
	my ($self, $mid, $ts, $xpath, $doc_data) = @_;
	my $w = $self->{w};
	my $err;
	my $str = freeze([ $mid, $ts, $xpath, $doc_data ]);
	my $len = length($str) . "\n";

	# multiple processes write to the same pipe, so use flock
	$self->_lock_acquire;
	print $w $len, $str or $err = $!;
	$self->_lock_release;

	die "print failed: $err\n" if $err;
}

sub thread_msg_real {
	my ($self, $mid, $ts, $xpath, $doc_data) = @_;
	my $smsg = $self->lookup_message($mid);
	my ($old_tid, $doc_id);
	if ($smsg) {
		# convert a ghost to a regular message
		# it will also clobber any existing regular message
		$doc_id = $smsg->{doc_id};
		$old_tid = $smsg->thread_id;
	} else {
		$smsg = PublicInbox::SearchMsg->new(undef);
		$smsg->{mid} = $mid;
	}
	my $doc = $smsg->{doc};
	$doc->add_term('XPATH' . $xpath) if defined $xpath;
	$doc->add_term('XMID' . $mid);
	$doc->set_data($doc_data);
	$smsg->{ts} = $ts;
	my @refs = ($smsg->references =~ /<([^>]+)>/g);
	$self->link_message($smsg, \@refs, $old_tid);
	my $db = $self->{xdb};
	if (defined $doc_id) {
		$db->replace_document($doc_id, $doc);
	} else {
		$doc_id = $db->add_document($doc);
	}
}

1;
