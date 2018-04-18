# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
package PublicInbox::V2Writable;
use strict;
use warnings;
use base qw(PublicInbox::Lock);
use PublicInbox::SearchIdxPart;
use PublicInbox::MIME;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::MID qw(mids);
use PublicInbox::ContentId qw(content_id content_digest);
use PublicInbox::Inbox;
use PublicInbox::OverIdx;
use PublicInbox::Msgmap;
use PublicInbox::Spawn;
use IO::Handle;

# an estimate of the post-packed size to the raw uncompressed size
my $PACKING_FACTOR = 0.4;

# assume 2 cores if GNU nproc(1) is not available
sub nproc_parts () {
	my $n = int($ENV{NPROC} || `nproc 2>/dev/null` || 2);
	# subtract for the main process and git-fast-import
	$n -= 1;
	$n < 1 ? 1 : $n;
}

sub count_partitions ($) {
	my ($self) = @_;
	my $nparts = 0;
	my $xpfx = $self->{xpfx};

	# always load existing partitions in case core count changes:
	# Also, partition count may change while -watch is running
	# due to -compact
	if (-d $xpfx) {
		foreach my $part (<$xpfx/*>) {
			-d $part && $part =~ m!/\d+\z! or next;
			eval {
				Search::Xapian::Database->new($part)->close;
				$nparts++;
			};
		}
	}
	$nparts;
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

	$v2ibx = PublicInbox::InboxWritable->new($v2ibx);

	my $xpfx = "$dir/xap" . PublicInbox::Search::SCHEMA_VERSION;
	my $self = {
		-inbox => $v2ibx,
		im => undef, #  PublicInbox::Import
		parallel => 1,
		transact_bytes => 0,
		xpfx => $xpfx,
		over => PublicInbox::OverIdx->new("$xpfx/over.sqlite3", 1),
		lock_path => "$dir/inbox.lock",
		# limit each git repo (epoch) to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
		last_commit => [], # git repo -> commit
	};
	$self->{partitions} = count_partitions($self) || nproc_parts();
	bless $self, $class;
}

sub init_inbox {
	my ($self, $parallel) = @_;
	$self->{parallel} = $parallel;
	$self->idx_init;
	my $epoch_max = -1;
	git_dir_latest($self, \$epoch_max);
	$self->git_init($epoch_max >= 0 ? $epoch_max : 0);
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
	$self->{last_commit}->[$self->{epoch_max}] = $cmt;

	my ($oid, $len, $msgref) = @{$im->{last_object}};
	$self->{over}->add_overview($mime, $len, $num, $oid, $mid0);
	my $nparts = $self->{partitions};
	my $part = $num % $nparts;
	my $idx = $self->idx_part($part);
	$idx->index_raw($len, $msgref, $num, $oid, $mid0, $mime);
	my $n = $self->{transact_bytes} += $len;
	if ($n > (PublicInbox::SearchIdx::BATCH_BYTES * $nparts)) {
		$self->checkpoint;
	}

	$cmt;
}

sub num_for {
	my ($self, $mime, $mid0) = @_;
	my $mids = mids($mime->header_obj);
	if (@$mids) {
		my $mid = $mids->[0];
		my $num = $self->{mm}->mid_insert($mid);
		if (defined $num) { # common case
			$$mid0 = $mid;
			return $num;
		};

		# crap, Message-ID is already known, hope somebody just resent:
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
		for(my $i = $#$mids; $i >= 1; $i--) {
			my $m = $mids->[$i];
			$num = $self->{mm}->mid_insert($m);
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
	my $num = $self->{mm}->mid_insert($$mid0);
	unless (defined $num) {
		# it's hard to spoof the last Received: header
		my @recvd = $hdr->header_raw('Received');
		$dig->add("Received: $_") foreach (@recvd);
		$$mid0 = PublicInbox::Import::digest2mid($dig);
		$num = $self->{mm}->mid_insert($$mid0);

		# fall back to a random Message-ID and give up determinism:
		until (defined($num)) {
			$dig->add(rand);
			$$mid0 = PublicInbox::Import::digest2mid($dig);
			warn "using random Message-ID <$$mid0> as fallback\n";
			$num = $self->{mm}->mid_insert($$mid0);
		}
	}
	PublicInbox::Import::append_mid($hdr, $$mid0);
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

       if ($self->{parallel}) {
               pipe(my ($r, $w)) or die "pipe failed: $!";
               $self->{bnote} = [ $r, $w ];
               $w->autoflush(1);
       }

	my $over = $self->{over};
	$ibx->umask_prepare;
	$ibx->with_umask(sub {
		$self->lock_acquire;
		$over->create;

		# -compact can change partition count while -watch is idle
		my $nparts = count_partitions($self);
		if ($nparts && $nparts != $self->{partitions}) {
			$self->{partitions} = $nparts;
		}

		# need to create all parts before initializing msgmap FD
		my $max = $self->{partitions} - 1;

		# idx_parts must be visible to all forked processes
		my $idx = $self->{idx_parts} = [];
		for my $i (0..$max) {
			push @$idx, PublicInbox::SearchIdxPart->new($self, $i);
		}

		# Now that all subprocesses are up, we can open the FDs
		# for SQLite:
		my $mm = $self->{mm} = PublicInbox::Msgmap->new_file(
			"$self->{-inbox}->{mainrepo}/msgmap.sqlite3", 1);
		$mm->{dbh}->begin_work;
	});
}

sub purge_oids {
	my ($self, $purge) = @_; # $purge = { $object_id => 1, ... }
	$self->done;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	my $purges = [];
	foreach my $i (0..$self->{epoch_max}) {
		my $git = PublicInbox::Git->new("$pfx/$i.git");
		my $im = $self->import_init($git, 0, 1);
		$purges->[$i] = $im->purge_oids($purge);
	}
	$purges;
}

sub remove_internal {
	my ($self, $mime, $cmt_msg, $purge) = @_;
	$self->idx_init;
	my $im = $self->importer unless $purge;
	my $over = $self->{over};
	my $cid = content_id($mime);
	my $parts = $self->{idx_parts};
	my $mm = $self->{mm};
	my $removed;
	my $mids = mids($mime->header_obj);

	# We avoid introducing new blobs into git since the raw content
	# can be slightly different, so we do not need the user-supplied
	# message now that we have the mids and content_id
	$mime = undef;
	my $mark;

	foreach my $mid (@$mids) {
		my %gone;
		my ($id, $prev);
		while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
			my $msg = get_blob($self, $smsg);
			if (!defined($msg)) {
				warn "broken smsg for $mid\n";
				next; # continue
			}
			my $orig = $$msg;
			my $cur = PublicInbox::MIME->new($msg);
			if (content_id($cur) eq $cid) {
				$smsg->{mime} = $cur;
				$gone{$smsg->{num}} = [ $smsg, \$orig ];
			}
		}
		my $n = scalar keys %gone;
		next unless $n;
		if ($n > 1) {
			warn "BUG: multiple articles linked to <$mid>\n",
				join(',', sort keys %gone), "\n";
		}
		foreach my $num (keys %gone) {
			my ($smsg, $orig) = @{$gone{$num}};
			$mm->num_delete($num);
			# $removed should only be set once assuming
			# no bugs in our deduplication code:
			$removed = $smsg;
			my $oid = $smsg->{blob};
			if ($purge) {
				$purge->{$oid} = 1;
			} else {
				($mark, undef) = $im->remove($orig, $cmt_msg);
			}
			$orig = undef;
			$self->unindex_oid_remote($oid, $mid);
		}
	}

	if (defined $mark) {
		my $cmt = $im->get_mark($mark);
		$self->{last_commit}->[$self->{epoch_max}] = $cmt;
	}
	if ($purge && scalar keys %$purge) {
		return purge_oids($self, $purge);
	}
	$removed;
}

sub remove {
	my ($self, $mime, $cmt_msg) = @_;
	remove_internal($self, $mime, $cmt_msg);
}

sub purge {
	my ($self, $mime) = @_;
	my $purges = remove_internal($self, $mime, undef, {});
	$self->idx_init if @$purges; # ->done is called on purges
	for my $i (0..$#$purges) {
		defined(my $cmt = $purges->[$i]) or next;
		$self->{last_commit}->[$i] = $cmt;
	}
	$purges;
}

sub last_commit_part ($$;$) {
	my ($self, $i, $cmt) = @_;
	my $v = PublicInbox::Search::SCHEMA_VERSION();
	$self->{mm}->last_commit_xap($v, $i, $cmt);
}

sub set_last_commits ($) {
	my ($self) = @_;
	defined(my $epoch_max = $self->{epoch_max}) or return;
	my $last_commit = $self->{last_commit};
	foreach my $i (0..$epoch_max) {
		defined(my $cmt = $last_commit->[$i]) or next;
		$last_commit->[$i] = undef;
		last_commit_part($self, $i, $cmt);
	}
}

sub barrier_init {
	my ($self, $n) = @_;
	$self->{bnote} or return;
	--$n;
	my $barrier = { map { $_ => 1 } (0..$n) };
}

sub barrier_wait {
	my ($self, $barrier) = @_;
	my $bnote = $self->{bnote} or return;
	my $r = $bnote->[0];
	while (scalar keys %$barrier) {
		defined(my $l = $r->getline) or die "EOF on barrier_wait: $!";
		$l =~ /\Abarrier (\d+)/ or die "bad line on barrier_wait: $l";
		delete $barrier->{$1} or die "bad part[$1] on barrier wait";
	}
}

sub checkpoint ($;$) {
	my ($self, $wait) = @_;

	if (my $im = $self->{im}) {
		if ($wait) {
			$im->barrier;
		} else {
			$im->checkpoint;
		}
	}
	my $parts = $self->{idx_parts};
	if ($parts) {
		my $dbh = $self->{mm}->{dbh};

		# SQLite msgmap data is second in importance
		$dbh->commit;

		# SQLite overview is third
		$self->{over}->commit_lazy;

		# Now deal with Xapian
		if ($wait) {
			my $barrier = $self->barrier_init(scalar @$parts);

			# each partition needs to issue a barrier command
			$_->remote_barrier for @$parts;

			# wait for each Xapian partition
			$self->barrier_wait($barrier);
		} else {
			$_->remote_commit for @$parts;
		}

		# last_commit is special, don't commit these until
		# remote partitions are done:
		$dbh->begin_work;
		set_last_commits($self);
		$dbh->commit;

		$dbh->begin_work;
	}
	$self->{transact_bytes} = 0;
}

# issue a write barrier to ensure all data is visible to other processes
# and read-only ops.  Order of data importance is: git > SQLite > Xapian
sub barrier { checkpoint($_[0], 1) };

sub done {
	my ($self) = @_;
	my $im = delete $self->{im};
	$im->done if $im; # PublicInbox::Import::done
	checkpoint($self);
	my $mm = delete $self->{mm};
	$mm->{dbh}->commit if $mm;
	my $parts = delete $self->{idx_parts};
	if ($parts) {
		$_->remote_close for @$parts;
	}
	$self->{over}->disconnect;
	delete $self->{bnote};
	$self->{transact_bytes} = 0;
	$self->lock_release if $parts;
}

sub git_init {
	my ($self, $epoch) = @_;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	my $git_dir = "$pfx/$epoch.git";
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
	my $new_obj_dir = "../../git/$epoch.git/objects";
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
			$im = undef;
			$self->checkpoint;
			my $git_dir = $self->git_init(++$self->{epoch_max});
			my $git = PublicInbox::Git->new($git_dir);
			return $self->import_init($git, 0);
		}
	}
	my $epoch = 0;
	my $max;
	my $latest = git_dir_latest($self, \$max);
	if (defined $latest) {
		my $git = PublicInbox::Git->new($latest);
		my $packed_bytes = $git->packed_bytes;
		if ($packed_bytes >= $self->{rotate_bytes}) {
			$epoch = $max + 1;
		} else {
			$self->{epoch_max} = $max;
			return $self->import_init($git, $packed_bytes);
		}
	}
	$self->{epoch_max} = $epoch;
	$latest = $self->git_init($epoch);
	$self->import_init(PublicInbox::Git->new($latest), 0);
}

sub import_init {
	my ($self, $git, $packed_bytes, $tmp) = @_;
	my $im = PublicInbox::Import->new($git, undef, undef, $self->{-inbox});
	$im->{bytes_added} = int($packed_bytes / $PACKING_FACTOR);
	$im->{want_object_info} = 1;
	$im->{lock_path} = undef;
	$im->{path_type} = 'v2';
	$self->{im} = $im unless $tmp;
	$im;
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

sub get_blob ($$) {
	my ($self, $smsg) = @_;
	if (my $im = $self->{im}) {
		my $msg = $im->cat_blob($smsg->{blob});
		return $msg if $msg;
	}
	# older message, should be in alternates
	my $ibx = $self->{-inbox};
	$ibx->msg_by_smsg($smsg);
}

sub lookup_content {
	my ($self, $mime, $mid) = @_;
	my $over = $self->{over};
	my $cid = content_id($mime);
	my $found;
	my ($id, $prev);
	while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
		my $msg = get_blob($self, $smsg);
		if (!defined($msg)) {
			warn "broken smsg for $mid\n";
			next;
		}
		my $cur = PublicInbox::MIME->new($msg);
		if (content_id($cur) eq $cid) {
			$smsg->{mime} = $cur;
			$found = $smsg;
			last;
		}

		# XXX DEBUG_DIFF is experimental and may be removed
		diff($mid, $cur, $mime) if $ENV{DEBUG_DIFF};
	}
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
	die "unexpected mm" if $self->{mm};
	close $self->{bnote}->[0] or die "close bnote[0]: $!\n";
	$self->{bnote}->[1];
}

sub mark_deleted {
	my ($self, $D, $git, $oid) = @_;
	my $msgref = $git->cat_file($oid);
	my $mime = PublicInbox::MIME->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $cid = content_id($mime);
	foreach my $mid (@$mids) {
		$D->{"$mid\0$cid"} = 1;
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
		$del += (delete $D->{"$mid\0$cid"} || 0);
		my $n = $mm_tmp->num_for($mid);
		if (defined $n && $n > $num) {
			$mid0 = $mid;
			$num = $n;
		}
	}
	if (!defined($mid0) && $regen && !$del) {
		$num = $$regen--;
		die "BUG: ran out of article numbers\n" if $num <= 0;
		my $mm = $self->{mm};
		foreach my $mid (reverse @$mids) {
			if ($mm->mid_set($num, $mid) == 1) {
				$mid0 = $mid;
				last;
			}
		}
		if (!defined($mid0)) {
			my $id = '<' . join('> <', @$mids) . '>';
			warn "Message-ID $id unusable for $num\n";
			foreach my $mid (@$mids) {
				defined(my $n = $mm->num_for($mid)) or next;
				warn "#$n previously mapped for <$mid>\n";
			}
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

	$self->{over}->add_overview($mime, $len, $num, $oid, $mid0);
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

# only update last_commit for $i on reindex iff newer than current
sub update_last_commit {
	my ($self, $git, $i, $cmt) = @_;
	my $last = last_commit_part($self, $i);
	if (defined $last && is_ancestor($git, $last, $cmt)) {
		my @cmd = (qw(rev-list --count), "$last..$cmt");
		chomp(my $n = $git->qx(@cmd));
		return if $n ne '' && $n == 0;
	}
	last_commit_part($self, $i, $cmt);
}

sub git_dir_n ($$) { "$_[0]->{-inbox}->{mainrepo}/git/$_[1].git" }

sub last_commits {
	my ($self, $epoch_max) = @_;
	my $heads = [];
	for (my $i = $epoch_max; $i >= 0; $i--) {
		$heads->[$i] = last_commit_part($self, $i);
	}
	$heads;
}

sub is_ancestor ($$$) {
	my ($git, $cur, $tip) = @_;
	return 0 unless $git->check($cur);
	my $cmd = [ 'git', "--git-dir=$git->{git_dir}",
		qw(merge-base --is-ancestor), $cur, $tip ];
	my $pid = spawn($cmd);
	defined $pid or die "spawning ".join(' ', @$cmd)." failed: $!";
	waitpid($pid, 0) == $pid or die join(' ', @$cmd) .' did not finish';
	$? == 0;
}

sub index_prepare {
	my ($self, $opts, $epoch_max, $ranges) = @_;
	my $regen_max = 0;
	my $head = $self->{-inbox}->{ref_head} || 'refs/heads/master';
	for (my $i = $epoch_max; $i >= 0; $i--) {
		die "already indexing!\n" if $self->{index_pipe};
		my $git_dir = git_dir_n($self, $i);
		-d $git_dir or next; # missing parts are fine
		my $git = PublicInbox::Git->new($git_dir);
		chomp(my $tip = $git->qx('rev-parse', $head));
		my $range;
		if (defined(my $cur = $ranges->[$i])) {
			$range = "$cur..$tip";
			if (is_ancestor($git, $cur, $tip)) { # common case
				my $n = $git->qx(qw(rev-list --count), $range);
				chomp($n);
				if ($n == 0) {
					$ranges->[$i] = undef;
					next;
				}
			} else {
				warn <<"";
discontiguous range: $range
Rewritten history? (in $git_dir)

				my $base = $git->qx('merge-base', $tip, $cur);
				chomp $base;
				if ($base) {
					$range = "$base..$tip";
					warn "found merge-base: $base\n"
				} else {
					$range = $tip;
					warn <<"";
discarding history at $cur

				}
				warn <<"";
reindexing $git_dir starting at
$range

				$self->{"unindex-range.$i"} = "$base..$cur";
			}
		} else {
			$range = $tip; # all of it
		}
		$ranges->[$i] = $range;

		# can't use 'rev-list --count' if we use --diff-filter
		my $fh = $git->popen(qw(log --pretty=tformat:%h
				--no-notes --no-color --no-renames
				--diff-filter=AM), $range, '--', 'm');
		++$regen_max while <$fh>;
	}
	\$regen_max;
}

sub unindex_oid_remote {
	my ($self, $oid, $mid) = @_;
	$_->remote_remove($oid, $mid) foreach @{$self->{idx_parts}};
	$self->{over}->remove_oid($oid, $mid);
}

sub unindex_oid {
	my ($self, $git, $oid) = @_;
	my $msgref = $git->cat_file($oid);
	my $mime = PublicInbox::MIME->new($msgref);
	my $mids = mids($mime->header_obj);
	$mime = $msgref = undef;
	my $over = $self->{over};
	foreach my $mid (@$mids) {
		my %gone;
		my ($id, $prev);
		while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
			$gone{$smsg->{num}} = 1 if $oid eq $smsg->{blob};
			1; # continue
		}
		my $n = scalar keys %gone;
		next unless $n;
		if ($n > 1) {
			warn "BUG: multiple articles linked to $oid\n",
				join(',',sort keys %gone), "\n";
		}
		$self->{unindexed}->{$_}++ foreach keys %gone;
		$self->unindex_oid_remote($oid, $mid);
	}
}

my $x40 = qr/[a-f0-9]{40}/;
sub unindex {
	my ($self, $opts, $git, $unindex_range) = @_;
	my $un = $self->{unindexed} ||= {}; # num => removal count
	my $before = scalar keys %$un;
	my @cmd = qw(log --raw -r
			--no-notes --no-color --no-abbrev --no-renames);
	my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $unindex_range);
	while (<$fh>) {
		/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o or next;
		$self->unindex_oid($git, $1);
	}
	delete $self->{reindex_pipe};
	$fh = undef;

	return unless $opts->{prune};
	my $after = scalar keys %$un;
	return if $before == $after;

	# ensure any blob can not longer be accessed via dumb HTTP
	PublicInbox::Import::run_die(['git', "--git-dir=$git->{git_dir}",
		qw(-c gc.reflogExpire=now gc --prune=all)]);
}

sub index_sync {
	my ($self, $opts) = @_;
	$opts ||= {};
	my $epoch_max;
	my $latest = git_dir_latest($self, \$epoch_max);
	return unless defined $latest;
	$self->idx_init; # acquire lock
	my $mm_tmp = $self->{mm}->tmp_clone;
	my $ranges = $opts->{reindex} ? [] : $self->last_commits($epoch_max);

	my ($min, $max) = $mm_tmp->minmax;
	my $regen = $self->index_prepare($opts, $epoch_max, $ranges);
	$$regen += $max if $max;
	my $D = {};
	my @cmd = qw(log --raw -r --pretty=tformat:%h
			--no-notes --no-color --no-abbrev --no-renames);

	# work backwards through history
	my $last_commit = [];
	for (my $i = $epoch_max; $i >= 0; $i--) {
		my $git_dir = git_dir_n($self, $i);
		die "already reindexing!\n" if delete $self->{reindex_pipe};
		-d $git_dir or next; # missing parts are fine
		my $git = PublicInbox::Git->new($git_dir);
		my $unindex = delete $self->{"unindex-range.$i"};
		$self->unindex($opts, $git, $unindex) if $unindex;
		defined(my $range = $ranges->[$i]) or next;
		my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $range);
		my $cmt;
		while (<$fh>) {
			if (/\A$x40$/o && !defined($cmt)) {
				chomp($cmt = $_);
			} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o) {
				$self->reindex_oid($mm_tmp, $D, $git, $1,
						$regen);
			} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\td$/o) {
				$self->mark_deleted($D, $git, $1);
			}
		}
		$fh = undef;
		delete $self->{reindex_pipe};
		$self->update_last_commit($git, $i, $cmt) if defined $cmt;
	}
	my @d = sort keys %$D;
	if (@d) {
		warn "BUG: ", scalar(@d)," unseen deleted messages marked\n";
		foreach (@d) {
			my ($mid, undef) = split(/\0/, $_, 2);
			warn "<$mid>\n";
		}
	}
	$self->done;
}

1;
