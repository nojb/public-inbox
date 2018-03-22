# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
package PublicInbox::V2Writable;
use strict;
use warnings;
use base qw(PublicInbox::Lock);
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
sub nproc () {
	int($ENV{NPROC} || `nproc 2>/dev/null` || 2);
}

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

	my $nparts = 0;
	my $xpfx = "$dir/xap" . PublicInbox::Search::SCHEMA_VERSION;

	# always load existing partitions in case core count changes:
	if (-d $xpfx) {
		foreach my $part (<$xpfx/*>) {
			-d $part && $part =~ m!/\d+\z! or next;
			eval {
				Search::Xapian::Database->new($part)->close;
				$nparts++;
			};
		}
	}
	$nparts = nproc() if ($nparts == 0);

	my $self = {
		-inbox => $v2ibx,
		im => undef, #  PublicInbox::Import
		xap_rw => undef, # PublicInbox::V2SearchIdx
		xap_ro => undef,
		partitions => $nparts,
		parallel => 1,
		transact_bytes => 0,
		lock_path => "$dir/inbox.lock",
		# limit each repo to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
	};
	bless $self, $class;
}

sub init_inbox {
	my ($self, $parallel) = @_;
	$self->{parallel} = $parallel;
	$self->idx_init;
	$self->git_init(0);
	$self->done;
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

	my $mid0;
	my $num = num_for($self, $mime, \$mid0);
	defined $num or return; # duplicate
	defined $mid0 or die "BUG: $mid0 undefined\n";
	my $im = $self->importer;
	my $cmt = $im->add($mime);
	$cmt = $im->get_mark($cmt);
	my ($oid, $len, $msgref) = @{$im->{last_object}};

	my $nparts = $self->{partitions};
	my $part = $num % $nparts;
	my $idx = $self->idx_part($part);
	$idx->index_raw($len, $msgref, $num, $oid, $mid0, $mime);
	my $n = $self->{transact_bytes} += $len;
	if ($n > (PublicInbox::SearchIdx::BATCH_BYTES * $nparts)) {
		$self->checkpoint;
	}

	$mime;
}

sub num_for {
	my ($self, $mime, $mid0) = @_;
	my $mids = mids($mime->header_obj);
	if (@$mids) {
		my $mid = $mids->[0];
		my $num = $self->{skel}->{mm}->mid_insert($mid);
		if (defined $num) { # common case
			$$mid0 = $mid;
			return $num;
		};

		# crap, Message-ID is already known, hope somebody just resent:
		$self->barrier;
		foreach my $m (@$mids) {
			# read-only lookup now safe to do after above barrier
			my $existing = $self->lookup_content($mime, $m);
			# easy, don't store duplicates
			# note: do not add more diagnostic info here since
			# it gets noisy on public-inbox-watch restarts
			return if $existing;
		}

		# very unlikely:
		warn "<$mid> reused for mismatched content\n";

		# try the rest of the mids
		foreach my $i (1..$#$mids) {
			my $m = $mids->[$i];
			$num = $self->{skel}->{mm}->mid_insert($m);
			if (defined $num) {
				warn "alternative <$m> for <$mid> found\n";
				$$mid0 = $m;
				return $num;
			}
		}
	}
	# none of the existing Message-IDs are good, generate a new one:
	num_for_harder($self, $mime, $mid0);
}

sub num_for_harder {
	my ($self, $mime, $mid0) = @_;

	my $hdr = $mime->header_obj;
	my $dig = content_digest($mime);
	$$mid0 = PublicInbox::Import::digest2mid($dig);
	my $num = $self->{skel}->{mm}->mid_insert($$mid0);
	unless (defined $num) {
		# it's hard to spoof the last Received: header
		my @recvd = $hdr->header_raw('Received');
		$dig->add("Received: $_") foreach (@recvd);
		$$mid0 = PublicInbox::Import::digest2mid($dig);
		$num = $self->{skel}->{mm}->mid_insert($$mid0);

		# fall back to a random Message-ID and give up determinism:
		until (defined($num)) {
			$dig->add(rand);
			$$mid0 = PublicInbox::Import::digest2mid($dig);
			warn "using random Message-ID <$$mid0> as fallback\n";
			$num = $self->{skel}->{mm}->mid_insert($$mid0);
		}
	}
	PublicInbox::Import::prepend_mid($hdr, $$mid0);
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

	$self->lock_acquire;

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
	my ($self, $mime, $cmt_msg) = @_;
	$self->barrier;
	$self->idx_init;
	my $im = $self->importer;
	my $ibx = $self->{-inbox};
	my $srch = $ibx->search;
	my $cid = content_id($mime);
	my $skel = $self->{skel};
	my $parts = $self->{idx_parts};
	my $mm = $skel->{mm};
	my $removed;
	my $mids = mids($mime->header_obj);

	# We avoid introducing new blobs into git since the raw content
	# can be slightly different, so we do not need the user-supplied
	# message now that we have the mids and content_id
	$mime = undef;

	foreach my $mid (@$mids) {
		$srch->reopen->each_smsg_by_mid($mid, sub {
			my ($smsg) = @_;
			$smsg->load_expand;
			my $msg = $ibx->msg_by_smsg($smsg);
			if (!defined($msg)) {
				warn "broken smsg for $mid\n";
				return 1; # continue
			}
			my $orig = $$msg;
			my $cur = PublicInbox::MIME->new($msg);
			if (content_id($cur) eq $cid) {
				$mm->num_delete($smsg->num);
				# $removed should only be set once assuming
				# no bugs in our deduplication code:
				$removed = $smsg;
				$removed->{mime} = $cur;
				$im->remove(\$orig, $cmt_msg);
				$orig = undef;
				$removed->num; # memoize this for callers

				my $oid = $smsg->{blob};
				foreach my $idx (@$parts, $skel) {
					$idx->remote_remove($oid, $mid);
				}
			}
			1; # continue
		});
		$self->barrier;
	}
	$removed;
}

sub done {
	my ($self) = @_;
	my $locked = defined $self->{idx_parts};
	my $im = delete $self->{im};
	$im->done if $im; # PublicInbox::Import::done
	$self->searchidx_checkpoint(0);
	$self->lock_release if $locked;
}

sub checkpoint {
	my ($self) = @_;
	my $im = $self->{im};
	$im->checkpoint if $im; # PublicInbox::Import::checkpoint
	$self->searchidx_checkpoint(1);
}

# issue a write barrier to ensure all data is visible to other processes
# and read-only ops.  Order of data importance is: git > SQLite > Xapian
sub barrier {
	my ($self) = @_;

	if (my $im = $self->{im}) {
		$im->barrier;
	}
	my $skel = $self->{skel};
	my $parts = $self->{idx_parts};
	if ($parts && $skel) {
		my $dbh = $skel->{mm}->{dbh};
		$dbh->commit; # SQLite data is second in importance

		# Now deal with Xapian
		$skel->barrier_init(scalar(@$parts));
		# each partition needs to issue a barrier command to skel:
		$_->remote_barrier foreach @$parts;

		$skel->barrier_wait; # wait for each Xapian partition

		$dbh->begin_work;
	}
	$self->{transact_bytes} = 0;
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

	my $all = "$self->{-inbox}->{mainrepo}/all.git";
	unless (-d $all) {
		@cmd = (qw(git init --bare -q), $all);
		PublicInbox::Import::run_die(\@cmd);
		@cmd = (qw/git config/, "--file=$all/config",
				'repack.writeBitmaps', 'true');
		PublicInbox::Import::run_die(\@cmd);
	}

	@cmd = (qw/git config/, "--file=$git_dir/config",
			'include.path', '../../all.git/config');
	PublicInbox::Import::run_die(\@cmd);

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

sub git_dir_latest {
	my ($self, $max) = @_;
	$$max = -1;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	return unless -d $pfx;
	my $latest;
	opendir my $dh, $pfx or die "opendir $pfx: $!\n";
	while (defined(my $git_dir = readdir($dh))) {
		$git_dir =~ m!\A(\d+)\.git\z! or next;
		if ($1 > $$max) {
			$$max = $1;
			$latest = "$pfx/$git_dir";
		}
	}
	$latest;
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
	my $new = 0;
	my $max;
	my $latest = git_dir_latest($self, \$max);
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
	$im->{want_object_info} = 1;
	$im->{lock_path} = undef;
	$im->{path_type} = 'v2';
	$self->{im} = $im;
}

# XXX experimental
sub diff ($$$) {
	my ($mid, $cur, $new) = @_;
	use File::Temp qw(tempfile);
	use PublicInbox::Spawn qw(spawn);

	my ($ah, $an) = tempfile('email-cur-XXXXXXXX', TMPDIR => 1);
	print $ah $cur->as_string or die "print: $!";
	close $ah or die "close: $!";
	my ($bh, $bn) = tempfile('email-new-XXXXXXXX', TMPDIR => 1);
	PublicInbox::Import::drop_unwanted_headers($new);
	print $bh $new->as_string or die "print: $!";
	close $bh or die "close: $!";
	my $cmd = [ qw(diff -u), $an, $bn ];
	print STDERR "# MID conflict <$mid>\n";
	my $pid = spawn($cmd, undef, { 1 => 2 });
	defined $pid or die "diff failed to spawn $!";
	waitpid($pid, 0) == $pid or die "diff did not finish";
	unlink($an, $bn);
}

sub lookup_content {
	my ($self, $mime, $mid) = @_;
	my $ibx = $self->{-inbox};

	my $srch = $ibx->search->reopen;
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

		# XXX DEBUG_DIFF is experimental and may be removed
		diff($mid, $cur, $mime) if $ENV{DEBUG_DIFF};

		1; # continue
	});
	$found;
}

sub atfork_child {
	my ($self) = @_;
	my $fh = delete $self->{reindex_pipe};
	close $fh if $fh;
	if (my $parts = $self->{idx_parts}) {
		$_->atfork_child foreach @$parts;
	}
	if (my $im = $self->{im}) {
		$im->atfork_child;
	}
}

sub mark_deleted {
	my ($self, $D, $git, $oid) = @_;
	my $msgref = $git->cat_file($oid);
	my $mime = PublicInbox::MIME->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $cid = content_id($mime);
	foreach my $mid (@$mids) {
		$D->{$mid.$cid} = 1;
	}
}

sub reindex_oid {
	my ($self, $mm_tmp, $D, $git, $oid, $regen) = @_;
	my $len;
	my $msgref = $git->cat_file($oid, \$len);
	my $mime = PublicInbox::MIME->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $cid = content_id($mime);

	# get the NNTP article number we used before, highest number wins
	# and gets deleted from mm_tmp;
	my $mid0;
	my $num = -1;
	my $del = 0;
	foreach my $mid (@$mids) {
		$del += (delete $D->{$mid.$cid} || 0);
		my $n = $mm_tmp->num_for($mid);
		if (defined $n && $n > $num) {
			$mid0 = $mid;
			$num = $n;
		}
	}
	if (!defined($mid0) && $regen && !$del) {
		$num = $$regen--;
		die "BUG: ran out of article numbers\n" if $num <= 0;
		my $mm = $self->{skel}->{mm};
		foreach my $mid (@$mids) {
			if ($mm->mid_set($num, $mid) == 1) {
				$mid0 = $mid;
				last;
			}
		}
		if (!defined($mid0)) {
			my $id = '<' . join('> <', @$mids) . '>';
			warn "Message-Id $id unusable for $num\n";
		}
	}

	if (!defined($mid0) || $del) {
		if (!defined($mid0) && $del) { # expected for deletes
			$$regen--;
			return
		}

		my $id = '<' . join('> <', @$mids) . '>';
		defined($mid0) or
			warn "Skipping $id, no article number found\n";
		if ($del && defined($mid0)) {
			warn "$id was deleted $del " .
				"time(s) but mapped to article #$num\n";
		}
		return;

	}
	$mm_tmp->mid_delete($mid0) or
		die "failed to delete <$mid0> for article #$num\n";

	my $nparts = $self->{partitions};
	my $part = $num % $nparts;
	my $idx = $self->idx_part($part);
	$idx->index_raw($len, $msgref, $num, $oid, $mid0, $mime);
	my $n = $self->{transact_bytes} += $len;
	if ($n > (PublicInbox::SearchIdx::BATCH_BYTES * $nparts)) {
		$git->cleanup;
		$mm_tmp->atfork_prepare;
		$self->done; # release lock
		# allow -watch or -mda to write...
		$self->idx_init; # reacquire lock
		$mm_tmp->atfork_parent;
	}
}

sub reindex {
	my ($self, $regen) = @_;
	my $ibx = $self->{-inbox};
	my $pfx = "$ibx->{mainrepo}/git";
	my $max_git;
	my $latest = git_dir_latest($self, \$max_git);
	return unless defined $latest;
	my $head = $ibx->{ref_head} || 'refs/heads/master';
	$self->idx_init; # acquire lock
	my $x40 = qr/[a-f0-9]{40}/;
	my $mm_tmp = $self->{skel}->{mm}->tmp_clone;
	if (!$regen) {
		my (undef, $max) = $mm_tmp->minmax;
		unless (defined $max) {
			$regen = 1;
			warn
"empty msgmap.sqlite3, regenerating article numbers\n";
		}
	}
	my $tip; # latest commit out of all git repos
	if ($regen) {
		my $regen_max = 0;
		for (my $cur = $max_git; $cur >= 0; $cur--) {
			die "already reindexing!\n" if $self->{reindex_pipe};
			my $git = PublicInbox::Git->new("$pfx/$cur.git");
			chomp($tip = $git->qx('rev-parse', $head)) unless $tip;
			my $h = $cur == $max_git ? $tip : $head;
			my @count = ('rev-list', '--count', $h, '--', 'm');
			$regen_max += $git->qx(@count);
		}
		die "No messages found in $pfx/*.git, bug?\n" unless $regen_max;
		$regen = \$regen_max;
	}
	my $D = {};
	my @cmd = qw(log --raw -r --pretty=tformat:%h
			--no-notes --no-color --no-abbrev);

	# if we are regenerating, we must not use a newer tip commit than what
	# the regeneration counter used:
	$tip ||= $head;

	# work backwards through history
	for (my $cur = $max_git; $cur >= 0; $cur--) {
		die "already reindexing!\n" if delete $self->{reindex_pipe};
		my $cmt;
		my $git_dir = "$pfx/$cur.git";
		my $git = PublicInbox::Git->new($git_dir);
		my $h = $cur == $max_git ? $tip : $head;
		my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $h);
		while (<$fh>) {
			if (/\A$x40$/o) {
				chomp($cmt = $_);
			} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o) {
				$self->reindex_oid($mm_tmp, $D, $git, $1,
						$regen);
			} elsif (m!\A:\d{6} 100644 $x40 ($x40) [AM]\t_/D$!o) {
				$self->mark_deleted($D, $git, $1);
			}
		}
		delete $self->{reindex_pipe};
	}
	my ($min, $max) = $mm_tmp->minmax;
	defined $max and die "leftover article numbers at $min..$max\n";
}

1;
