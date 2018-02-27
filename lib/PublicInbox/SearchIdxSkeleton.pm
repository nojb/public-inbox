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
		eval { skeleton_worker_loop($self, $r) };
		die "skeleton worker died: $@\n" if $@;
		exit;
	}
	$self->{w} = $w;
	$self->{pid} = $pid;
	close $r;

	$w->autoflush(1);

	# lock on only exists in parent, not in worker
	my $l = $self->{lock_path} = $self->xdir . '/pi-v2-skeleton.lock';
	open my $fh, '>>', $l or die "failed to create $l: $!\n";
	$self;
}

sub skeleton_worker_loop {
	my ($self, $r) = @_;
	$0 = 'pi-v2-skeleton';
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
			eval { index_skeleton_real($self, $msg) };
			warn "failed to index message <$msg->[-1]>: $@\n" if $@;
		}
	}
}

# called by a partition worker
sub index_skeleton {
	my ($self, $values) = @_;
	my $w = $self->{w};
	my $err;
	my $str = freeze($values);
	$str = length($str) . "\n" . $str;

	# multiple processes write to the same pipe, so use flock
	$self->_lock_acquire;
	print $w $str or $err = $!;
	$self->_lock_release;

	die "print failed: $err\n" if $err;
}

# values: [ TS, NUM, BYTES, LINES, MID, XPATH, doc_data ]
sub index_skeleton_real ($$) {
	my ($self, $values) = @_;
	my $doc_data = pop @$values;
	my $xpath = pop @$values;
	my $mid = pop @$values;
	my $ts = $values->[PublicInbox::Search::TS];
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
	PublicInbox::SearchIdx::add_values($doc, $values);
	$doc->set_data($doc_data);
	$smsg->{ts} = $ts;
	$smsg->load_from_data($doc_data);
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
