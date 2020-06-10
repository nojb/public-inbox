# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# used to interface with a single Xapian shard in V2 repos.
# See L<public-inbox-v2-format(5)> for more info on how we shard Xapian
package PublicInbox::SearchIdxShard;
use strict;
use warnings;
use base qw(PublicInbox::SearchIdx);
use IO::Handle (); # autoflush
use PublicInbox::Eml;

sub new {
	my ($class, $v2writable, $shard) = @_;
	my $ibx = $v2writable->{-inbox};
	my $self = $class->SUPER::new($ibx, 1, $shard);
	# create the DB before forking:
	$self->_xdb_acquire;
	$self->set_indexlevel;
	$self->_xdb_release;
	$self->spawn_worker($v2writable, $shard) if $v2writable->{parallel};
	$self;
}

sub spawn_worker {
	my ($self, $v2w, $shard) = @_;
	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
	binmode $r, ':raw';
	binmode $w, ':raw';
	$w->autoflush(1);
	my $pid = fork;
	defined $pid or die "fork failed: $!\n";
	if ($pid == 0) {
		my $bnote = $v2w->atfork_child;
		close $w or die "failed to close: $!";

		# F_SETPIPE_SZ = 1031 on Linux; increasing the pipe size here
		# speeds V2Writable batch imports across 8 cores by nearly 20%
		fcntl($r, 1031, 1048576) if $^O eq 'linux';

		eval { shard_worker_loop($self, $v2w, $r, $shard, $bnote) };
		die "worker $shard died: $@\n" if $@;
		die "unexpected MM $self->{mm}" if $self->{mm};
		exit;
	}
	$self->{pid} = $pid;
	$self->{w} = $w;
	close $r or die "failed to close: $!";
}

sub shard_worker_loop ($$$$$) {
	my ($self, $v2w, $r, $shard, $bnote) = @_;
	$0 = "pi-v2-shard[$shard]";
	$self->begin_txn_lazy;
	while (my $line = readline($r)) {
		$v2w->{current_info} = "[$shard] $line";
		if ($line eq "commit\n") {
			$self->commit_txn_lazy;
		} elsif ($line eq "close\n") {
			$self->_xdb_release;
		} elsif ($line eq "barrier\n") {
			$self->commit_txn_lazy;
			# no need to lock < 512 bytes is atomic under POSIX
			print $bnote "barrier $shard\n" or
					die "write failed for barrier $!\n";
		} elsif ($line =~ /\AD ([a-f0-9]{40,}) (.+)\n\z/s) {
			my ($oid, $mid) = ($1, $2);
			$self->begin_txn_lazy;
			$self->remove_by_oid($oid, $mid);
		} else {
			chomp $line;
			# n.b. $mid may contain spaces(!)
			my ($to_read, $bytes, $num, $blob, $ds, $ts, $mid) =
							split(/ /, $line, 7);
			$self->begin_txn_lazy;
			my $n = read($r, my $msg, $to_read) or die "read: $!\n";
			$n == $to_read or die "short read: $n != $to_read\n";
			my $mime = PublicInbox::Eml->new(\$msg);
			my $smsg = bless {
				bytes => $bytes,
				num => $num + 0,
				blob => $blob,
				mid => $mid,
				ds => $ds,
				ts => $ts,
			}, 'PublicInbox::Smsg';
			$self->add_message($mime, $smsg);
		}
	}
	$self->worker_done;
}

# called by V2Writable
sub index_raw {
	my ($self, $msgref, $mime, $smsg) = @_;
	if (my $w = $self->{w}) {
		# mid must be last, it can contain spaces (but not LF)
		print $w join(' ', @$smsg{qw(raw_bytes bytes
						num blob ds ts mid)}),
			"\n", $$msgref or die "failed to write shard $!\n";
	} else {
		$$msgref = undef;
		$self->begin_txn_lazy;
		$self->add_message($mime, $smsg);
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
	} else {
		$self->commit_txn_lazy;
	}
}

1;
