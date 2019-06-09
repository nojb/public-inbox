# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
# Used to write to V2 inboxes (see L<public-inbox-v2-format(5)>).
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
use PublicInbox::Spawn qw(spawn);
use PublicInbox::SearchIdx;
use IO::Handle;

# an estimate of the post-packed size to the raw uncompressed size
my $PACKING_FACTOR = 0.4;

# assume 2 cores if GNU nproc(1) is not available
sub nproc_parts ($) {
	my ($creat_opt) = @_;
	if (ref($creat_opt) eq 'HASH') {
		if (defined(my $n = $creat_opt->{nproc})) {
			return $n
		}
	}

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
			-d $part && $part =~ m!/[0-9]+\z! or next;
			eval {
				Search::Xapian::Database->new($part)->close;
				$nparts++;
			};
		}
	}
	$nparts;
}

sub new {
	# $creat may be any true value, or 0/undef.  A hashref is true,
	# and $creat->{nproc} may be set to an integer
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
	$v2ibx->umask_prepare;

	my $xpfx = "$dir/xap" . PublicInbox::Search::SCHEMA_VERSION;
	my $self = {
		-inbox => $v2ibx,
		im => undef, #  PublicInbox::Import
		parallel => 1,
		transact_bytes => 0,
		current_info => '',
		xpfx => $xpfx,
		over => PublicInbox::OverIdx->new("$xpfx/over.sqlite3", 1),
		lock_path => "$dir/inbox.lock",
		# limit each git repo (epoch) to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
		last_commit => [], # git repo -> commit
	};
	$self->{partitions} = count_partitions($self) || nproc_parts($creat);
	bless $self, $class;
}

# public (for now?)
sub init_inbox {
	my ($self, $parallel, $skip_epoch) = @_;
	$self->{parallel} = $parallel;
	$self->idx_init;
	my $epoch_max = -1;
	git_dir_latest($self, \$epoch_max);
	if (defined $skip_epoch && $epoch_max == -1) {
		$epoch_max = $skip_epoch;
	}
	$self->git_init($epoch_max >= 0 ? $epoch_max : 0);
	$self->done;
}

# returns undef on duplicate or spam
# mimics Import::add and wraps it for v2
sub add {
	my ($self, $mime, $check_cb) = @_;
	$self->{-inbox}->with_umask(sub {
		_add($self, $mime, $check_cb)
	});
}

# indexes a message, returns true if checkpointing is needed
sub do_idx ($$$$$$$) {
	my ($self, $msgref, $mime, $len, $num, $oid, $mid0) = @_;
	$self->{over}->add_overview($mime, $len, $num, $oid, $mid0);
	my $npart = $self->{partitions};
	my $part = $num % $npart;
	my $idx = idx_part($self, $part);
	$idx->index_raw($len, $msgref, $num, $oid, $mid0, $mime);
	my $n = $self->{transact_bytes} += $len;
	$n >= (PublicInbox::SearchIdx::BATCH_BYTES * $npart);
}

sub _add {
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
	if (do_idx($self, $msgref, $mime, $len, $num, $oid, $mid0)) {
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
			my $existing = lookup_content($self, $mime, $m);
			# easy, don't store duplicates
			# note: do not add more diagnostic info here since
			# it gets noisy on public-inbox-watch restarts
			return if $existing;
		}

		# AltId may pre-populate article numbers (e.g. X-Mail-Count
		# or NNTP article number), use that article number if it's
		# not in Over.
		my $altid = $self->{-inbox}->{altid};
		if ($altid && grep(/:file=msgmap\.sqlite3\z/, @$altid)) {
			my $num = $self->{mm}->num_for($mid);

			if (defined $num && !$self->{over}->get_art($num)) {
				$$mid0 = $mid;
				return $num;
			}
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
	$$mid0 = PublicInbox::Import::digest2mid($dig, $hdr);
	my $num = $self->{mm}->mid_insert($$mid0);
	unless (defined $num) {
		# it's hard to spoof the last Received: header
		my @recvd = $hdr->header_raw('Received');
		$dig->add("Received: $_") foreach (@recvd);
		$$mid0 = PublicInbox::Import::digest2mid($dig, $hdr);
		$num = $self->{mm}->mid_insert($$mid0);

		# fall back to a random Message-ID and give up determinism:
		until (defined($num)) {
			$dig->add(rand);
			$$mid0 = PublicInbox::Import::digest2mid($dig, $hdr);
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
	my ($self, $opt) = @_;
	return if $self->{idx_parts};
	my $ibx = $self->{-inbox};

	# do not leak read-only FDs to child processes, we only have these
	# FDs for duplicate detection so they should not be
	# frequently activated.
	delete $ibx->{$_} foreach (qw(git mm search));

	my $indexlevel = $ibx->{indexlevel};
	if ($indexlevel && $indexlevel eq 'basic') {
		$self->{parallel} = 0;
	}

	if ($self->{parallel}) {
		pipe(my ($r, $w)) or die "pipe failed: $!";
		# pipe for barrier notifications doesn't need to be big,
		# 1031: F_SETPIPE_SZ
		fcntl($w, 1031, 4096) if $^O eq 'linux';
		$self->{bnote} = [ $r, $w ];
		$w->autoflush(1);
	}

	my $over = $self->{over};
	$ibx->umask_prepare;
	$ibx->with_umask(sub {
		$self->lock_acquire unless ($opt && $opt->{-skip_lock});
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

sub purge_oids ($$) {
	my ($self, $purge) = @_; # $purge = { $object_id => \'', ... }
	$self->done;
	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	my $purges = [];
	my $max = $self->{epoch_max};

	unless (defined($max)) {
		defined(my $latest = git_dir_latest($self, \$max)) or return;
		$self->{epoch_max} = $max;
	}
	foreach my $i (0..$max) {
		my $git_dir = "$pfx/$i.git";
		-d $git_dir or next;
		my $git = PublicInbox::Git->new($git_dir);
		my $im = $self->import_init($git, 0, 1);
		$purges->[$i] = $im->replace_oids($purge);
		$im->done;
	}
	$purges;
}

sub content_ids ($) {
	my ($mime) = @_;
	my @cids = ( content_id($mime) );

	# Email::MIME->as_string doesn't always round-trip, so we may
	# use a second content_id
	my $rt = content_id(PublicInbox::MIME->new(\($mime->as_string)));
	push @cids, $rt if $cids[0] ne $rt;
	\@cids;
}

sub content_matches ($$) {
	my ($cids, $existing) = @_;
	my $cid = content_id($existing);
	foreach (@$cids) {
		return 1 if $_ eq $cid
	}
	0
}

sub remove_internal ($$$$) {
	my ($self, $mime, $cmt_msg, $purge) = @_;
	$self->idx_init;
	my $im = $self->importer unless $purge;
	my $over = $self->{over};
	my $cids = content_ids($mime);
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
			if (content_matches($cids, $cur)) {
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
				$purge->{$oid} = \'';
			} else {
				($mark, undef) = $im->remove($orig, $cmt_msg);
			}
			$orig = undef;
			unindex_oid_remote($self, $oid, $mid);
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

# public
sub remove {
	my ($self, $mime, $cmt_msg) = @_;
	$self->{-inbox}->with_umask(sub {
		remove_internal($self, $mime, $cmt_msg, undef);
	});
}

# public
sub purge {
	my ($self, $mime) = @_;
	my $purges = $self->{-inbox}->with_umask(sub {
		remove_internal($self, $mime, undef, {});
	}) or return;
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

# public
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
# public
sub barrier { checkpoint($_[0], 1) };

# public
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
	$self->{-inbox}->git->cleanup;
}

sub fill_alternates ($$) {
	my ($self, $epoch) = @_;

	my $pfx = "$self->{-inbox}->{mainrepo}/git";
	my $all = "$self->{-inbox}->{mainrepo}/all.git";
	my @cmd;
	unless (-d $all) {
		PublicInbox::Import::init_bare($all);
	}
	@cmd = (qw/git config/, "--file=$pfx/$epoch.git/config",
			'include.path', '../../all.git/config');
	PublicInbox::Import::run_die(\@cmd);

	my $alt = "$all/objects/info/alternates";
	my %alts;
	my @add;
	if (-e $alt) {
		open(my $fh, '<', $alt) or die "open < $alt: $!\n";
		%alts = map { chomp; $_ => 1 } (<$fh>);
	}
	foreach my $i (0..$epoch) {
		my $dir = "../../git/$i.git/objects";
		push @add, $dir if !$alts{$dir} && -d "$pfx/$i.git";
	}
	return unless @add;
	open my $fh, '>>', $alt or die "open >> $alt: $!\n";
	foreach my $dir (@add) {
		print $fh "$dir\n" or die "print >> $alt: $!\n";
	}
	close $fh or die "close $alt: $!\n";
}

sub git_init {
	my ($self, $epoch) = @_;
	my $git_dir = "$self->{-inbox}->{mainrepo}/git/$epoch.git";
	my @cmd = (qw(git init --bare -q), $git_dir);
	PublicInbox::Import::run_die(\@cmd);
	fill_alternates($self, $epoch);
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
		$git_dir =~ m!\A([0-9]+)\.git\z! or next;
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
		my $unpacked_bytes = $packed_bytes / $PACKING_FACTOR;

		if ($unpacked_bytes >= $self->{rotate_bytes}) {
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

sub lookup_content ($$$) {
	my ($self, $mime, $mid) = @_;
	my $over = $self->{over};
	my $cids = content_ids($mime);
	my ($id, $prev);
	while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
		my $msg = get_blob($self, $smsg);
		if (!defined($msg)) {
			warn "broken smsg for $mid\n";
			next;
		}
		my $cur = PublicInbox::MIME->new($msg);
		if (content_matches($cids, $cur)) {
			$smsg->{mime} = $cur;
			return $smsg;
		}


		# XXX DEBUG_DIFF is experimental and may be removed
		diff($mid, $cur, $mime) if $ENV{DEBUG_DIFF};
	}
	undef;
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

sub mark_deleted ($$$$) {
	my ($self, $sync, $git, $oid) = @_;
	my $msgref = $git->cat_file($oid);
	my $mime = PublicInbox::MIME->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $cid = content_id($mime);
	foreach my $mid (@$mids) {
		$sync->{D}->{"$mid\0$cid"} = $oid;
	}
}

sub reindex_oid ($$$$) {
	my ($self, $sync, $git, $oid) = @_;
	my $len;
	my $msgref = $git->cat_file($oid, \$len);
	my $mime = PublicInbox::MIME->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $cid = content_id($mime);

	# get the NNTP article number we used before, highest number wins
	# and gets deleted from sync->{mm_tmp};
	my $mid0;
	my $num = -1;
	my $del = 0;
	foreach my $mid (@$mids) {
		$del += delete($sync->{D}->{"$mid\0$cid"}) ? 1 : 0;
		my $n = $sync->{mm_tmp}->num_for($mid);
		if (defined $n && $n > $num) {
			$mid0 = $mid;
			$num = $n;
			$self->{mm}->mid_set($num, $mid0);
		}
	}
	if (!defined($mid0) && !$del) {
		$num = $sync->{regen}--;
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
			$num = $sync->{regen}--;
			$self->{mm}->num_highwater($num) if !$sync->{reindex};
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
	$sync->{mm_tmp}->mid_delete($mid0) or
		die "failed to delete <$mid0> for article #$num\n";
	$sync->{nr}++;
	if (do_idx($self, $msgref, $mime, $len, $num, $oid, $mid0)) {
		$git->cleanup;
		$sync->{mm_tmp}->atfork_prepare;
		$self->done; # release lock

		if (my $pr = $sync->{-opt}->{-progress}) {
			my ($bn) = (split('/', $git->{git_dir}))[-1];
			$pr->("$bn ".sprintf($sync->{-regen_fmt}, $sync->{nr}));
		}

		# allow -watch or -mda to write...
		$self->idx_init; # reacquire lock
		$sync->{mm_tmp}->atfork_parent;
	}
}

# only update last_commit for $i on reindex iff newer than current
sub update_last_commit ($$$$) {
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

sub last_commits ($$) {
	my ($self, $epoch_max) = @_;
	my $heads = [];
	for (my $i = $epoch_max; $i >= 0; $i--) {
		$heads->[$i] = last_commit_part($self, $i);
	}
	$heads;
}

*is_ancestor = *PublicInbox::SearchIdx::is_ancestor;

# returns a revision range for git-log(1)
sub log_range ($$$$$) {
	my ($self, $sync, $git, $i, $tip) = @_;
	my $opt = $sync->{-opt};
	my $pr = $opt->{-progress} if (($opt->{verbose} || 0) > 1);
	my $cur = $sync->{ranges}->[$i] or do {
		$pr->("$i.git indexing all of $tip") if $pr;
		return $tip; # all of it
	};

	# fast equality check to avoid (v)fork+execve overhead
	if ($cur eq $tip) {
		$sync->{ranges}->[$i] = undef;
		return;
	}

	my $range = "$cur..$tip";
	$pr->("$i.git checking contiguity... ") if $pr;
	if (is_ancestor($git, $cur, $tip)) { # common case
		$pr->("OK\n") if $pr;
		my $n = $git->qx(qw(rev-list --count), $range);
		chomp($n);
		if ($n == 0) {
			$sync->{ranges}->[$i] = undef;
			$pr->("$i.git has nothing new\n") if $pr;
			return; # nothing to do
		}
		$pr->("$i.git has $n changes since $cur\n") if $pr;
	} else {
		$pr->("FAIL\n") if $pr;
		warn <<"";
discontiguous range: $range
Rewritten history? (in $git->{git_dir})

		chomp(my $base = $git->qx('merge-base', $tip, $cur));
		if ($base) {
			$range = "$base..$tip";
			warn "found merge-base: $base\n"
		} else {
			$range = $tip;
			warn "discarding history at $cur\n";
		}
		warn <<"";
reindexing $git->{git_dir} starting at
$range

		$sync->{unindex_range}->{$i} = "$base..$cur";
	}
	$range;
}

sub sync_prepare ($$$) {
	my ($self, $sync, $epoch_max) = @_;
	my $pr = $sync->{-opt}->{-progress};
	my $regen_max = 0;
	my $head = $self->{-inbox}->{ref_head} || 'refs/heads/master';

	# reindex stops at the current heads and we later rerun index_sync
	# without {reindex}
	my $reindex_heads = last_commits($self, $epoch_max) if $sync->{reindex};

	for (my $i = $epoch_max; $i >= 0; $i--) {
		die 'BUG: already indexing!' if $self->{reindex_pipe};
		my $git_dir = git_dir_n($self, $i);
		-d $git_dir or next; # missing parts are fine
		my $git = PublicInbox::Git->new($git_dir);
		if ($reindex_heads) {
			$head = $reindex_heads->[$i] or next;
		}
		chomp(my $tip = $git->qx(qw(rev-parse -q --verify), $head));

		next if $?; # new repo
		my $range = log_range($self, $sync, $git, $i, $tip) or next;
		$sync->{ranges}->[$i] = $range;

		# can't use 'rev-list --count' if we use --diff-filter
		$pr->("$i.git counting $range ... ") if $pr;
		my $n = 0;
		my $fh = $git->popen(qw(log --pretty=tformat:%H
				--no-notes --no-color --no-renames
				--diff-filter=AM), $range, '--', 'm');
		++$n while <$fh>;
		$pr->("$n\n") if $pr;
		$regen_max += $n;
	}

	return 0 if (!$regen_max && !keys(%{$self->{unindex_range}}));

	# reindex should NOT see new commits anymore, if we do,
	# it's a problem and we need to notice it via die()
	my $pad = length($regen_max) + 1;
	$sync->{-regen_fmt} = "% ${pad}u/$regen_max\n";
	$sync->{nr} = 0;
	return -1 if $sync->{reindex};
	$regen_max + $self->{mm}->num_highwater() || 0;
}

sub unindex_oid_remote ($$$) {
	my ($self, $oid, $mid) = @_;
	$_->remote_remove($oid, $mid) foreach @{$self->{idx_parts}};
	$self->{over}->remove_oid($oid, $mid);
}

sub unindex_oid ($$$) {
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
		foreach my $num (keys %gone) {
			$self->{unindexed}->{$_}++;
			$self->{mm}->num_delete($num);
		}
		unindex_oid_remote($self, $oid, $mid);
	}
}

my $x40 = qr/[a-f0-9]{40}/;
sub unindex ($$$$) {
	my ($self, $sync, $git, $unindex_range) = @_;
	my $un = $self->{unindexed} ||= {}; # num => removal count
	my $before = scalar keys %$un;
	my @cmd = qw(log --raw -r
			--no-notes --no-color --no-abbrev --no-renames);
	my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $unindex_range);
	while (<$fh>) {
		/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o or next;
		unindex_oid($self, $git, $1);
	}
	delete $self->{reindex_pipe};
	$fh = undef;

	return unless $sync->{-opt}->{prune};
	my $after = scalar keys %$un;
	return if $before == $after;

	# ensure any blob can not longer be accessed via dumb HTTP
	PublicInbox::Import::run_die(['git', "--git-dir=$git->{git_dir}",
		qw(-c gc.reflogExpire=now gc --prune=all)]);
}

sub sync_ranges ($$$) {
	my ($self, $sync, $epoch_max) = @_;
	my $reindex = $sync->{reindex};

	return last_commits($self, $epoch_max) unless $reindex;
	return [] if ref($reindex) ne 'HASH';

	my $ranges = $reindex->{from}; # arrayref;
	if (ref($ranges) ne 'ARRAY') {
		die 'BUG: $reindex->{from} not an ARRAY';
	}
	$ranges;
}

sub index_epoch ($$$) {
	my ($self, $sync, $i) = @_;

	my $git_dir = git_dir_n($self, $i);
	die 'BUG: already reindexing!' if $self->{reindex_pipe};
	-d $git_dir or return; # missing parts are fine
	fill_alternates($self, $i);
	my $git = PublicInbox::Git->new($git_dir);
	if (my $unindex_range = delete $sync->{unindex_range}->{$i}) {
		unindex($self, $sync, $git, $unindex_range);
	}
	defined(my $range = $sync->{ranges}->[$i]) or return;
	if (my $pr = $sync->{-opt}->{-progress}) {
		$pr->("$i.git indexing $range\n");
	}

	my @cmd = qw(log --raw -r --pretty=tformat:%H
			--no-notes --no-color --no-abbrev --no-renames);
	my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $range);
	my $cmt;
	while (<$fh>) {
		chomp;
		$self->{current_info} = "$i.git $_";
		if (/\A$x40$/o && !defined($cmt)) {
			$cmt = $_;
		} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o) {
			reindex_oid($self, $sync, $git, $1);
		} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\td$/o) {
			mark_deleted($self, $sync, $git, $1);
		}
	}
	$fh = undef;
	delete $self->{reindex_pipe};
	update_last_commit($self, $git, $i, $cmt) if defined $cmt;
}

# public, called by public-inbox-index
sub index_sync {
	my ($self, $opt) = @_;
	$opt ||= {};
	my $pr = $opt->{-progress};
	my $epoch_max;
	my $latest = git_dir_latest($self, \$epoch_max);
	return unless defined $latest;
	$self->idx_init($opt); # acquire lock
	my $sync = {
		D => {}, # "$mid\0$cid" => $oid
		unindex_range => {}, # EPOCH => oid_old..oid_new
		reindex => $opt->{reindex},
		-opt => $opt
	};
	$sync->{ranges} = sync_ranges($self, $sync, $epoch_max);
	$sync->{regen} = sync_prepare($self, $sync, $epoch_max);

	if ($sync->{regen}) {
		# tmp_clone seems to fail if inside a transaction, so
		# we rollback here (because we opened {mm} for reading)
		# Note: we do NOT rely on DBI transactions for atomicity;
		# only for batch performance.
		$self->{mm}->{dbh}->rollback;
		$self->{mm}->{dbh}->begin_work;
		$sync->{mm_tmp} = $self->{mm}->tmp_clone;
	}

	# work backwards through history
	for (my $i = $epoch_max; $i >= 0; $i--) {
		index_epoch($self, $sync, $i);
	}

	# unindex is required for leftovers if "deletes" affect messages
	# in a previous fetch+index window:
	if (my @leftovers = values %{delete $sync->{D}}) {
		my $git = $self->{-inbox}->git;
		unindex_oid($self, $git, $_) for @leftovers;
		$git->cleanup;
	}
	$self->done;

	if (my $nr = $sync->{nr}) {
		my $pr = $sync->{-opt}->{-progress};
		$pr->('all.git '.sprintf($sync->{-regen_fmt}, $nr)) if $pr;
	}

	# reindex does not pick up new changes, so we rerun w/o it:
	if ($opt->{reindex}) {
		my %again = %$opt;
		$sync = undef;
		delete @again{qw(reindex -skip_lock)};
		index_sync($self, \%again);
	}
}

1;
