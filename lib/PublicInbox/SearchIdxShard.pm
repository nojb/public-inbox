# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Internal interface for a single Xapian shard in V2 inboxes.
# See L<public-inbox-v2-format(5)> for more info on how we shard Xapian
package PublicInbox::SearchIdxShard;
use strict;
use v5.10.1;
use parent qw(PublicInbox::SearchIdx);
use bytes qw(length);
use IO::Handle (); # autoflush
use PublicInbox::Eml;

sub new {
	my ($class, $v2w, $shard) = @_; # v2w may be ExtSearchIdx
	my $ibx = $v2w->{ibx};
	my $self = $ibx ? $class->SUPER::new($ibx, 1, $shard)
			: $class->eidx_shard_new($v2w, $shard);
	# create the DB before forking:
	$self->idx_acquire;
	$self->set_metadata_once;
	$self->idx_release;
	$self->spawn_worker($v2w, $shard) if $v2w->{parallel};
	$self;
}

sub spawn_worker {
	my ($self, $v2w, $shard) = @_;
	my ($r, $w);
	pipe($r, $w) or die "pipe failed: $!\n";
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

sub eml ($$) {
	my ($r, $len) = @_;
	my $n = read($r, my $bref, $len) or die "read: $!\n";
	$n == $len or die "short read: $n != $len\n";
	PublicInbox::Eml->new(\$bref);
}

# this reads all the writes to $self->{w} from the parent process
sub shard_worker_loop ($$$$$) {
	my ($self, $v2w, $r, $shard, $bnote) = @_;
	$0 = "shard[$shard]";
	$self->begin_txn_lazy;
	while (my $line = readline($r)) {
		$v2w->{current_info} = "[$shard] $line";
		if ($line eq "commit\n") {
			$self->commit_txn_lazy;
		} elsif ($line eq "close\n") {
			$self->idx_release;
		} elsif ($line eq "barrier\n") {
			$self->commit_txn_lazy;
			# no need to lock < 512 bytes is atomic under POSIX
			print $bnote "barrier $shard\n" or
					die "write failed for barrier $!\n";
		} elsif ($line =~ /\AD ([a-f0-9]{40,}) ([0-9]+)\n\z/s) {
			$self->remove_by_oid($1, $2 + 0);
		} elsif ($line =~ s/\A\+X //) {
			my ($len, $docid, $xnum, $oid, $eidx_key) =
							split(/ /, $line, 5);
			$self->add_xref3($docid, $xnum, $oid, $eidx_key,
						eml($r, $len));
		} elsif ($line =~ s/\A-X //) {
			my ($len, $docid, $xnum, $oid, $eidx_key) =
							split(/ /, $line, 5);
			$self->remove_xref3($docid, $xnum, $oid,
						$eidx_key, eml($r, $len));
		} else {
			chomp $line;
			my $eidx_key;
			if ($line =~ s/\AX(.+)\0//) {
				$eidx_key = $1;
			}
			# n.b. $mid may contain spaces(!)
			my ($len, $bytes, $num, $oid, $ds, $ts, $tid, $mid)
				= split(/ /, $line, 8);
			$self->begin_txn_lazy;
			my $smsg = bless {
				bytes => $bytes,
				num => $num + 0,
				blob => $oid,
				mid => $mid,
				tid => $tid,
				ds => $ds,
				ts => $ts,
			}, 'PublicInbox::Smsg';
			$smsg->{eidx_key} = $eidx_key if defined($eidx_key);
			$self->add_message(eml($r, $len), $smsg);
		}
	}
	$self->worker_done;
}

sub index_raw {
	my ($self, $msgref, $eml, $smsg, $ibx) = @_;
	if (my $w = $self->{w}) {
		if ($ibx) {
			print $w 'X', $ibx->eidx_key, "\0" or die
				"failed to write shard: $!\n";
		}
		$msgref //= \($eml->as_string);
		$smsg->{raw_bytes} //= length($$msgref);
		# mid must be last, it can contain spaces (but not LF)
		print $w join(' ', @$smsg{qw(raw_bytes bytes
						num blob ds ts tid mid)}),
			"\n", $$msgref or die "failed to write shard $!\n";
	} else {
		if ($eml) {
			undef($$msgref) if $msgref;
		} else { # --xapian-only + --sequential-shard:
			$eml = PublicInbox::Eml->new($msgref);
		}
		$self->begin_txn_lazy;
		$smsg->{eidx_key} = $ibx->eidx_key if $ibx;
		$self->add_message($eml, $smsg);
	}
}

sub shard_add_xref3 {
	my ($self, $docid, $xnum, $oid, $xibx, $eml) = @_;
	my $eidx_key = $xibx->eidx_key;
	if (my $w = $self->{w}) {
		my $hdr = $eml->header_obj->as_string;
		my $len = length($hdr);
		print $w "+X $len $docid $xnum $oid $eidx_key\n", $hdr or
			die "failed to write shard: $!";
	} else {
		$self->add_xref3($docid, $xnum, $oid, $eidx_key, $eml);
	}
}

sub shard_remove_xref3 {
	my ($self, $docid, $oid, $xibx, $eml) = @_;
	my $eidx_key = $xibx->eidx_key;
	if (my $w = $self->{w}) {
		my $hdr = $eml->header_obj->as_string;
		my $len = length($hdr);
		print $w "-X $len $docid $oid $eidx_key\n", $hdr or
			die "failed to write shard: $!";
	} else {
		$self->remove_xref3($docid, $oid, $eidx_key, $eml);
	}
}

sub atfork_child {
	close $_[0]->{w} or die "failed to close write pipe: $!\n";
}

sub shard_barrier {
	my ($self) = @_;
	if (my $w = $self->{w}) {
		print $w "barrier\n" or die "failed to print: $!";
	} else {
		$self->commit_txn_lazy;
	}
}

sub shard_commit {
	my ($self) = @_;
	if (my $w = $self->{w}) {
		print $w "commit\n" or die "failed to write commit: $!";
	} else {
		$self->commit_txn_lazy;
	}
}

sub shard_close {
	my ($self) = @_;
	if (my $w = delete $self->{w}) {
		my $pid = delete $self->{pid} or die "no process to wait on\n";
		print $w "close\n" or die "failed to write to pid:$pid: $!\n";
		close $w or die "failed to close pipe for pid:$pid: $!\n";
		waitpid($pid, 0) == $pid or die "remote process did not finish";
		$? == 0 or die ref($self)." pid:$pid exited with: $?";
	} else {
		die "transaction in progress $self\n" if $self->{txn};
		$self->idx_release if $self->{xdb};
	}
}

sub shard_remove {
	my ($self, $oid, $num) = @_;
	if (my $w = $self->{w}) { # triggers remove_by_oid in a shard child
		print $w "D $oid $num\n" or die "failed to write remove $!";
	} else { # same process
		$self->remove_by_oid($oid, $num);
	}
}

1;
