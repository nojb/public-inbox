# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
package PublicInbox::V2Writable;
use strict;
use warnings;
use Fcntl qw(:flock :DEFAULT);
use PublicInbox::SearchIdxPart;
use PublicInbox::SearchIdxSkeleton;
use PublicInbox::MIME;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::MID qw(mids);
use PublicInbox::ContentId qw(content_id content_digest);
use PublicInbox::Inbox;

# an estimate of the post-packed size to the raw uncompressed size
my $PACKING_FACTOR = 0.4;

# assume 2 cores if GNU nproc(1) is not available
my $NPROC = int($ENV{NPROC} || `nproc 2>/dev/null` || 2);

sub new {
	my ($class, $v2ibx, $creat) = @_;
	my $dir = $v2ibx->{mainrepo} or die "no mainrepo in inbox\n";
	unless (-d $dir) {
		if ($creat) {
			require File::Path;
			File::Path::mkpath($dir);
		} else {
			die "$dir does not exist\n";
		}
	}
	my $self = {
		-inbox => $v2ibx,
		im => undef, #  PublicInbox::Import
		xap_rw => undef, # PublicInbox::V2SearchIdx
		xap_ro => undef,
		partitions => $NPROC,
		transact_bytes => 0,
		# limit each repo to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
	};
	bless $self, $class
}

# returns undef on duplicate or spam
# mimics Import::add and wraps it for v2
sub add {
	my ($self, $mime, $check_cb) = @_;

	# spam check:
	if ($check_cb) {
		$mime = $check_cb->($mime) or return;
	}

	# All pipes (> $^F) known to Perl 5.6+ have FD_CLOEXEC set,
	# as does SQLite 3.4.1+ (released in 2007-07-20), and
	# Xapian 1.3.2+ (released 2015-03-15).
	# For the most part, we can spawn git-fast-import without
	# leaking FDs to it...
	$self->idx_init;

	my $num = num_for($self, $mime);
	defined $num or return; # duplicate
	my $im = $self->importer;
	my $cmt = $im->add($mime);
	$cmt = $im->get_mark($cmt);
	my $oid = $im->{last_object_id};
	my ($len, $msgref) = @{$im->{last_object}};

	my $nparts = $self->{partitions};
	my $part = $num % $nparts;
	my $idx = $self->idx_part($part);
	$idx->index_raw($len, $msgref, $num, $oid);
	my $n = $self->{transact_bytes} += $len;
	if ($n > (PublicInbox::SearchIdx::BATCH_BYTES * $nparts)) {
		$self->checkpoint;
	}

	$mime;
}

sub num_for {
	my ($self, $mime) = @_;
	my $mids = mids($mime->header_obj);
	if (@$mids) {
		my $mid = $mids->[0];
		my $num = $self->{skel}->{mm}->mid_insert($mid);
		return $num if defined($num); # common case

		# crap, Message-ID is already known, hope somebody just resent:
		$self->done; # write barrier, clears $self->{skel}
		foreach my $m (@$mids) {
			# read-only lookup now safe to do after above barrier
			my $existing = $self->lookup_content($mime, $m);
			if ($existing) {
				warn "<$m> resent\n";
				return; # easy, don't store duplicates
			}
		}

		# very unlikely:
		warn "<$mid> reused for mismatched content\n";
		$self->idx_init;

		# try the rest of the mids
		foreach my $i (1..$#$mids) {
			my $m = $mids->[$i];
			$num = $self->{skel}->{mm}->mid_insert($m);
			if (defined $num) {
				warn "alternative <$m> for <$mid> found\n";
				return $num;
			}
		}
	}
	# none of the existing Message-IDs are good, generate a new one:
	num_for_harder($self, $mime);
}

sub num_for_harder {
	my ($self, $mime) = @_;

	my $hdr = $mime->header_obj;
	my $dig = content_digest($mime);
	my $mid = $dig->clone->hexdigest . '@localhost';
	my $num = $self->{skel}->{mm}->mid_insert($mid);
	unless (defined $num) {
		# it's hard to spoof the last Received: header
		my @recvd = $hdr->header_raw('Received');
		$dig->add("Received: $_") foreach (@recvd);
		$mid = $dig->clone->hexdigest . '@localhost';
		$num = $self->{skel}->{mm}->mid_insert($mid);

		# fall back to a random Message-ID and give up determinism:
		until (defined($num)) {
			$dig->add(rand);
			$mid = $dig->clone->hexdigest . '@localhost';
			warn "using random Message-ID <$mid> as fallback\n";
			$num = $self->{skel}->{mm}->mid_insert($mid);
		}
	}
	my @cur = $hdr->header_raw('Message-Id');
	$hdr->header_set('Message-Id', "<$mid>", @cur);
	$num;
}

sub idx_part {
	my ($self, $part) = @_;
	$self->{idx_parts}->[$part];
}

# idempotent
sub idx_init {
	my ($self) = @_;
	return if $self->{idx_parts};
	my $ibx = $self->{-inbox};

	# do not leak read-only FDs to child processes, we only have these
	# FDs for duplicate detection so they should not be
	# frequently activated.
	delete $ibx->{$_} foreach (qw(git mm search));

	# first time initialization, first we create the skeleton pipe:
	my $skel = $self->{skel} = PublicInbox::SearchIdxSkeleton->new($self);

	# need to create all parts before initializing msgmap FD
	my $max = $self->{partitions} - 1;
	my $idx = $self->{idx_parts} = [];
	for my $i (0..$max) {
		push @$idx, PublicInbox::SearchIdxPart->new($self, $i, $skel);
	}

	# Now that all subprocesses are up, we can open the FD for SQLite:
	$skel->_msgmap_init->{dbh}->begin_work;
}

sub remove {
	my ($self, $mime, $msg) = @_;
	my $existing = $self->lookup_content($mime) or return;

	# don't touch ghosts or already junked messages
	return unless $existing->type eq 'mail';

	# always write removals to the current (latest) git repo since
	# we process chronologically
	my $im = $self->importer;
	my ($cmt, undef) = $im->remove($mime, $msg);
	$cmt = $im->get_mark($cmt);
	$self->unindex_msg($existing, $cmt);
}

sub done {
	my ($self) = @_;
	my $im = delete $self->{im};
	$im->done if $im; # PublicInbox::Import::done
	$self->searchidx_checkpoint(0);
}

sub checkpoint {
	my ($self) = @_;
	my $im = $self->{im};
	$im->checkpoint if $im; # PublicInbox::Import::checkpoint
	$self->searchidx_checkpoint(1);
}

sub searchidx_checkpoint {
	my ($self, $more) = @_;

	# order matters, we can only close {skel} after all partitions
	# are done because the partitions also write to {skel}
	if (my $parts = $self->{idx_parts}) {
		foreach my $idx (@$parts) {
			$idx->remote_commit; # propagates commit to skel
			$idx->remote_close unless $more;
		}
		delete $self->{idx_parts} unless $more;
	}

	if (my $skel = $self->{skel}) {
		my $dbh = $skel->{mm}->{dbh};
		$dbh->commit;
		if ($more) {
			$dbh->begin_work;
		} else {
			$skel->remote_commit; # XXX should be unnecessary...
			$skel->remote_close;
			delete $self->{skel};
		}
	}
	$self->{transact_bytes} = 0;
}

sub git_init {
	my ($self, $new) = @_;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	my $git_dir = "$pfx/$new.git";
	die "$git_dir exists\n" if -e $git_dir;
	my @cmd = (qw(git init --bare -q), $git_dir);
	PublicInbox::Import::run_die(\@cmd);
	@cmd = (qw/git config/, "--file=$git_dir/config",
			'repack.writeBitmaps', 'true');
	PublicInbox::Import::run_die(\@cmd);

	my $all = "$self->{-inbox}->{mainrepo}/all.git";
	unless (-d $all) {
		@cmd = (qw(git init --bare -q), $all);
		PublicInbox::Import::run_die(\@cmd);
	}

	my $alt = "$all/objects/info/alternates";
	my $new_obj_dir = "../../git/$new.git/objects";
	my %alts;
	if (-e $alt) {
		open(my $fh, '<', $alt) or die "open < $alt: $!\n";
		%alts = map { chomp; $_ => 1 } (<$fh>);
	}
	return $git_dir if $alts{$new_obj_dir};
	open my $fh, '>>', $alt or die "open >> $alt: $!\n";
	print $fh "$new_obj_dir\n" or die "print >> $alt: $!\n";
	close $fh or die "close $alt: $!\n";
	$git_dir
}

sub importer {
	my ($self) = @_;
	my $im = $self->{im};
	if ($im) {
		if ($im->{bytes_added} < $self->{rotate_bytes}) {
			return $im;
		} else {
			$self->{im} = undef;
			$im->done;
			$self->searchidx_checkpoint(1);
			$im = undef;
			my $git_dir = $self->git_init(++$self->{max_git});
			my $git = PublicInbox::Git->new($git_dir);
			return $self->import_init($git, 0);
		}
	}
	my $latest;
	my $max = -1;
	my $new = 0;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	if (-d $pfx) {
		foreach my $git_dir (glob("$pfx/*.git")) {
			$git_dir =~ m!/(\d+)\.git\z! or next;
			my $n = $1;
			if ($n > $max) {
				$max = $n;
				$latest = $git_dir;
			}
		}
	}
	if (defined $latest) {
		my $git = PublicInbox::Git->new($latest);
		my $packed_bytes = $git->packed_bytes;
		if ($packed_bytes >= $self->{rotate_bytes}) {
			$new = $max + 1;
		} else {
			$self->{max_git} = $max;
			return $self->import_init($git, $packed_bytes);
		}
	}
	$self->{max_git} = $new;
	$latest = $self->git_init($new);
	$self->import_init(PublicInbox::Git->new($latest), 0);
}

sub import_init {
	my ($self, $git, $packed_bytes) = @_;
	my $im = PublicInbox::Import->new($git, undef, undef, $self->{-inbox});
	$im->{bytes_added} = int($packed_bytes / $PACKING_FACTOR);
	$im->{want_object_id} = 1;
	$im->{ssoma_lock} = 0;
	$im->{path_type} = 'v2';
	$self->{im} = $im;
}

sub lookup_content {
	my ($self, $mime, $mid) = @_;
	my $ibx = $self->{-inbox};

	my $srch = $ibx->search;
	my $cid = content_id($mime);
	my $found;
	$srch->each_smsg_by_mid($mid, sub {
		my ($smsg) = @_;
		$smsg->load_expand;
		my $msg = $ibx->msg_by_smsg($smsg);
		if (!defined($msg)) {
			warn "broken smsg for $mid\n";
			return 1; # continue
		}
		my $cur = PublicInbox::MIME->new($msg);
		if (content_id($cur) eq $cid) {
			$smsg->{mime} = $cur;
			$found = $smsg;
			return 0; # break out of loop
		}
		1; # continue
	});
	$found;
}

sub atfork_child {
	my ($self) = @_;
	if (my $parts = $self->{idx_parts}) {
		$_->atfork_child foreach @$parts;
	}
	if (my $im = $self->{im}) {
		$im->atfork_child;
	}
}

1;
