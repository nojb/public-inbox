# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
# Used to write to V2 inboxes (see L<public-inbox-v2-format(5)>).
package PublicInbox::V2Writable;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock PublicInbox::IPC);
use PublicInbox::SearchIdxShard;
use PublicInbox::IPC;
use PublicInbox::Eml;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::MultiGit;
use PublicInbox::MID qw(mids references);
use PublicInbox::ContentHash qw(content_hash content_digest git_sha);
use PublicInbox::InboxWritable;
use PublicInbox::OverIdx;
use PublicInbox::Msgmap;
use PublicInbox::Spawn qw(spawn popen_rd run_die);
use PublicInbox::Search;
use PublicInbox::SearchIdx qw(log2stack is_ancestor check_size is_bad_blob);
use IO::Handle; # ->autoflush
use File::Temp ();
use POSIX ();

my $OID = qr/[a-f0-9]{40,}/;
# an estimate of the post-packed size to the raw uncompressed size
our $PACKING_FACTOR = 0.4;

# SATA storage lags behind what CPUs are capable of, so relying on
# nproc(1) can be misleading and having extra Xapian shards is a
# waste of FDs and space.  It can also lead to excessive IO latency
# and slow things down.  Users on NVME or other fast storage can
# use the NPROC env or switches in our script/public-inbox-* programs
# to increase Xapian shards
our $NPROC_MAX_DEFAULT = 4;

sub nproc_shards ($) {
	my ($creat_opt) = @_;
	my $n = $creat_opt->{nproc} if ref($creat_opt) eq 'HASH';
	$n //= $ENV{NPROC};
	if (!$n) {
		# assume 2 cores if not detectable or zero
		state $NPROC_DETECTED = PublicInbox::IPC::detect_nproc() || 2;
		$n = $NPROC_DETECTED;
		$n = $NPROC_MAX_DEFAULT if $n > $NPROC_MAX_DEFAULT;
	}

	# subtract for the main process and git-fast-import
	$n -= 1;
	$n < 1 ? 1 : $n;
}

sub count_shards ($) {
	my ($self) = @_;
	# always load existing shards in case core count changes:
	# Also, shard count may change while -watch is running
	if (my $ibx = $self->{ibx}) {
		my $srch = $ibx->search or return 0;
		delete $ibx->{search};
		$srch->{nshard} // 0
	} else { # ExtSearchIdx
		$self->{nshard} = scalar($self->xdb_shards_flat);
	}
}

sub new {
	# $creat may be any true value, or 0/undef.  A hashref is true,
	# and $creat->{nproc} may be set to an integer
	my ($class, $v2ibx, $creat) = @_;
	$v2ibx = PublicInbox::InboxWritable->new($v2ibx);
	my $dir = $v2ibx->assert_usable_dir;
	unless (-d $dir) {
		die "$dir does not exist\n" if !$creat;
		require File::Path;
		File::Path::mkpath($dir);
	}
	my $xpfx = "$dir/xap" . PublicInbox::Search::SCHEMA_VERSION;
	my $self = {
		ibx => $v2ibx,
		mg => PublicInbox::MultiGit->new($dir, 'all.git', 'git'),
		im => undef, #  PublicInbox::Import
		parallel => 1,
		transact_bytes => 0,
		total_bytes => 0,
		current_info => '',
		xpfx => $xpfx,
		oidx => PublicInbox::OverIdx->new("$xpfx/over.sqlite3"),
		lock_path => "$dir/inbox.lock",
		# limit each git repo (epoch) to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
		last_commit => [], # git epoch -> commit
	};
	$self->{oidx}->{-no_fsync} = 1 if $v2ibx->{-no_fsync};
	$self->{shards} = count_shards($self) || nproc_shards($creat);
	bless $self, $class;
}

# public (for now?)
sub init_inbox {
	my ($self, $shards, $skip_epoch, $skip_artnum) = @_;
	if (defined $shards) {
		$self->{parallel} = 0 if $shards == 0;
		$self->{shards} = $shards if $shards > 0;
	}
	$self->idx_init;
	$self->{mm}->skip_artnum($skip_artnum) if defined $skip_artnum;
	my $max = $self->{ibx}->max_git_epoch;
	$max = $skip_epoch if (defined($skip_epoch) && !defined($max));
	$self->{mg}->add_epoch($max // 0);
	$self->done;
}

# returns undef on duplicate or spam
# mimics Import::add and wraps it for v2
sub add {
	my ($self, $eml, $check_cb) = @_;
	$self->{ibx}->with_umask(\&_add, $self, $eml, $check_cb);
}

sub idx_shard ($$) {
	my ($self, $num) = @_;
	$self->{idx_shards}->[$num % scalar(@{$self->{idx_shards}})];
}

# indexes a message, returns true if checkpointing is needed
sub do_idx ($$$) {
	my ($self, $eml, $smsg) = @_;
	$self->{oidx}->add_overview($eml, $smsg);
	if ($self->{-need_xapian}) {
		my $idx = idx_shard($self, $smsg->{num});
		$idx->index_eml($eml, $smsg);
	}
	my $n = $self->{transact_bytes} += $smsg->{bytes};
	$n >= $self->{batch_bytes};
}

sub _add {
	my ($self, $mime, $check_cb) = @_;

	# spam check:
	if ($check_cb) {
		$mime = $check_cb->($mime, $self->{ibx}) or return;
	}

	# All pipes (> $^F) known to Perl 5.6+ have FD_CLOEXEC set,
	# as does SQLite 3.4.1+ (released in 2007-07-20), and
	# Xapian 1.3.2+ (released 2015-03-15).
	# For the most part, we can spawn git-fast-import without
	# leaking FDs to it...
	$self->idx_init;

	my ($num, $mid0) = v2_num_for($self, $mime);
	defined $num or return; # duplicate
	defined $mid0 or die "BUG: \$mid0 undefined\n";
	my $im = $self->importer;
	my $smsg = bless { mid => $mid0, num => $num }, 'PublicInbox::Smsg';
	my $cmt = $im->add($mime, undef, $smsg); # sets $smsg->{ds|ts|blob}
	$cmt = $im->get_mark($cmt);
	$self->{last_commit}->[$self->{epoch_max}] = $cmt;

	if (do_idx($self, $mime, $smsg)) {
		$self->checkpoint;
	}

	$cmt;
}

sub v2_num_for {
	my ($self, $mime) = @_;
	my $mids = mids($mime);
	if (@$mids) {
		my $mid = $mids->[0];
		my $num = $self->{mm}->mid_insert($mid);
		if (defined $num) { # common case
			return ($num, $mid);
		}

		# crap, Message-ID is already known, hope somebody just resent:
		foreach my $m (@$mids) {
			# read-only lookup now safe to do after above barrier
			# easy, don't store duplicates
			# note: do not add more diagnostic info here since
			# it gets noisy on public-inbox-watch restarts
			return () if content_exists($self, $mime, $m);
		}

		# AltId may pre-populate article numbers (e.g. X-Mail-Count
		# or NNTP article number), use that article number if it's
		# not in Over.
		my $altid = $self->{ibx}->{altid};
		if ($altid && grep(/:file=msgmap\.sqlite3\z/, @$altid)) {
			my $num = $self->{mm}->num_for($mid);

			if (defined $num && !$self->{oidx}->get_art($num)) {
				return ($num, $mid);
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
				return ($num, $m);
			}
		}
	}
	# none of the existing Message-IDs are good, generate a new one:
	v2_num_for_harder($self, $mime);
}

sub v2_num_for_harder {
	my ($self, $eml) = @_;

	my $dig = content_digest($eml);
	my $mid0 = PublicInbox::Import::digest2mid($dig, $eml);
	my $num = $self->{mm}->mid_insert($mid0);
	unless (defined $num) {
		# it's hard to spoof the last Received: header
		my @recvd = $eml->header_raw('Received');
		$dig->add("Received: $_") foreach (@recvd);
		$mid0 = PublicInbox::Import::digest2mid($dig, $eml);
		$num = $self->{mm}->mid_insert($mid0);

		# fall back to a random Message-ID and give up determinism:
		until (defined($num)) {
			$dig->add(rand);
			$mid0 = PublicInbox::Import::digest2mid($dig, $eml);
			warn "using random Message-ID <$mid0> as fallback\n";
			$num = $self->{mm}->mid_insert($mid0);
		}
	}
	PublicInbox::Import::append_mid($eml, $mid0);
	($num, $mid0);
}

sub _idx_init { # with_umask callback
	my ($self, $opt) = @_;
	$self->lock_acquire unless $opt && $opt->{-skip_lock};
	$self->{oidx}->create;

	# xcpdb can change shard count while -watch is idle
	my $nshards = count_shards($self);
	$self->{shards} = $nshards if $nshards && $nshards != $self->{shards};
	$self->{batch_bytes} = $opt->{batch_size} //
				$PublicInbox::SearchIdx::BATCH_BYTES;

	# need to create all shards before initializing msgmap FD
	# idx_shards must be visible to all forked processes
	my $max = $self->{shards} - 1;
	my $idx = $self->{idx_shards} = [];
	push @$idx, PublicInbox::SearchIdxShard->new($self, $_) for (0..$max);
	$self->{-need_xapian} = $idx->[0]->need_xapian;

	# SearchIdxShard may do their own flushing, so don't scale
	# until after forking
	$self->{batch_bytes} *= $self->{shards} if $self->{parallel};

	my $ibx = $self->{ibx} or return; # ExtIdxSearch

	# Now that all subprocesses are up, we can open the FDs
	# for SQLite:
	my $mm = $self->{mm} = PublicInbox::Msgmap->new_file($ibx, 1);
	$mm->{dbh}->begin_work;
}

sub parallel_init ($$) {
	my ($self, $indexlevel) = @_;
	$self->{parallel} = 0 if ($indexlevel // 'full') eq 'basic';
}

# idempotent
sub idx_init {
	my ($self, $opt) = @_;
	return if $self->{idx_shards};
	my $ibx = $self->{ibx};

	# do not leak read-only FDs to child processes, we only have these
	# FDs for duplicate detection so they should not be
	# frequently activated.
	delete @$ibx{qw(mm search)};
	$ibx->git->cleanup;

	parallel_init($self, $ibx->{indexlevel});
	$ibx->with_umask(\&_idx_init, $self, $opt);
}

# returns an array mapping [ epoch => latest_commit ]
# latest_commit may be undef if nothing was done to that epoch
# $replace_map = { $object_id => $strref, ... }
sub _replace_oids ($$$) {
	my ($self, $mime, $replace_map) = @_;
	$self->done;
	my $ibx = $self->{ibx};
	my $pfx = "$ibx->{inboxdir}/git";
	my $rewrites = []; # epoch => commit
	my $max = $self->{epoch_max} //= $ibx->max_git_epoch // return;

	foreach my $i (0..$max) {
		my $git_dir = "$pfx/$i.git";
		-d $git_dir or next;
		my $git = PublicInbox::Git->new($git_dir);
		my $im = $self->import_init($git, 0, 1);
		$rewrites->[$i] = $im->replace_oids($mime, $replace_map);
		$im->done;
	}
	$rewrites;
}

sub content_hashes ($) {
	my ($mime) = @_;
	my @chashes = ( content_hash($mime) );

	# We still support Email::MIME, here, and
	# Email::MIME->as_string doesn't always round-trip, so we may
	# use a second content_hash
	my $rt = content_hash(PublicInbox::Eml->new(\($mime->as_string)));
	push @chashes, $rt if $chashes[0] ne $rt;
	\@chashes;
}

sub content_matches ($$) {
	my ($chashes, $existing) = @_;
	my $chash = content_hash($existing);
	foreach (@$chashes) {
		return 1 if $_ eq $chash
	}
	0
}

# used for removing or replacing (purging)
sub rewrite_internal ($$;$$$) {
	my ($self, $old_eml, $cmt_msg, $new_eml, $sref) = @_;
	$self->idx_init;
	my ($im, $need_reindex, $replace_map);
	if ($sref) {
		$replace_map = {}; # oid => sref
		$need_reindex = [] if $new_eml;
	} else {
		$im = $self->importer;
	}
	my $oidx = $self->{oidx};
	my $chashes = content_hashes($old_eml);
	my $removed = [];
	my $mids = mids($old_eml);

	# We avoid introducing new blobs into git since the raw content
	# can be slightly different, so we do not need the user-supplied
	# message now that we have the mids and content_hash
	$old_eml = undef;
	my $mark;

	foreach my $mid (@$mids) {
		my %gone; # num => [ smsg, $mime, raw ]
		my ($id, $prev);
		while (my $smsg = $oidx->next_by_mid($mid, \$id, \$prev)) {
			my $msg = get_blob($self, $smsg);
			if (!defined($msg)) {
				warn "broken smsg for $mid\n";
				next; # continue
			}
			my $orig = $$msg;
			my $cur = PublicInbox::Eml->new($msg);
			if (content_matches($chashes, $cur)) {
				$gone{$smsg->{num}} = [ $smsg, $cur, \$orig ];
			}
		}
		my $n = scalar keys %gone;
		next unless $n;
		if ($n > 1) {
			warn "BUG: multiple articles linked to <$mid>\n",
				join(',', sort keys %gone), "\n";
		}
		foreach my $num (keys %gone) {
			my ($smsg, $mime, $orig) = @{$gone{$num}};
			# $removed should only be set once assuming
			# no bugs in our deduplication code:
			$removed = [ undef, $mime, $smsg ];
			my $oid = $smsg->{blob};
			if ($replace_map) {
				$replace_map->{$oid} = $sref;
			} else {
				($mark, undef) = $im->remove($orig, $cmt_msg);
				$removed->[0] = $mark;
			}
			$orig = undef;
			if ($need_reindex) { # ->replace
				push @$need_reindex, $smsg;
			} else { # ->purge or ->remove
				$self->{mm}->num_delete($num);
			}
			unindex_oid_aux($self, $oid, $mid);
		}
	}

	if (defined $mark) {
		my $cmt = $im->get_mark($mark);
		$self->{last_commit}->[$self->{epoch_max}] = $cmt;
	}
	if ($replace_map && scalar keys %$replace_map) {
		my $rewrites = _replace_oids($self, $new_eml, $replace_map);
		return { rewrites => $rewrites, need_reindex => $need_reindex };
	}
	defined($mark) ? $removed : undef;
}

# public (see PublicInbox::Import->remove), but note the 3rd element
# (retval[2]) is not part of the stable API shared with Import->remove
sub remove {
	my ($self, $eml, $cmt_msg) = @_;
	my $r = $self->{ibx}->with_umask(\&rewrite_internal,
						$self, $eml, $cmt_msg);
	defined($r) && defined($r->[0]) ? @$r: undef;
}

sub _replace ($$;$$) {
	my ($self, $old_eml, $new_eml, $sref) = @_;
	my $arg = [ $self, $old_eml, undef, $new_eml, $sref ];
	my $rewritten = $self->{ibx}->with_umask(\&rewrite_internal,
			$self, $old_eml, undef, $new_eml, $sref) or return;

	my $rewrites = $rewritten->{rewrites};
	# ->done is called if there are rewrites since we gc+prune from git
	$self->idx_init if @$rewrites;

	for my $i (0..$#$rewrites) {
		defined(my $cmt = $rewrites->[$i]) or next;
		$self->{last_commit}->[$i] = $cmt;
	}
	$rewritten;
}

# public
sub purge {
	my ($self, $mime) = @_;
	my $rewritten = _replace($self, $mime, undef, \'') or return;
	$rewritten->{rewrites}
}

sub _check_mids_match ($$$) {
	my ($old_list, $new_list, $hdrs) = @_;
	my %old_mids = map { $_ => 1 } @$old_list;
	my %new_mids = map { $_ => 1 } @$new_list;
	my @old = keys %old_mids;
	my @new = keys %new_mids;
	my $err = "$hdrs may not be changed when replacing\n";
	die $err if scalar(@old) != scalar(@new);
	delete @new_mids{@old};
	delete @old_mids{@new};
	die $err if (scalar(keys %old_mids) || scalar(keys %new_mids));
}

# Changing Message-IDs or References with ->replace isn't supported.
# The rules for dealing with messages with multiple or conflicting
# Message-IDs are pretty complex and rethreading hasn't been fully
# implemented, yet.
sub check_mids_match ($$) {
	my ($old, $new) = @_;
	_check_mids_match(mids($old), mids($new), 'Message-ID(s)');
	_check_mids_match(references($old), references($new),
			'References/In-Reply-To');
}

# public
sub replace ($$$) {
	my ($self, $old_mime, $new_mime) = @_;

	check_mids_match($old_mime, $new_mime);

	# mutt will always add Content-Length:, Status:, Lines: when editing
	PublicInbox::Import::drop_unwanted_headers($new_mime);

	my $raw = $new_mime->as_string;
	my $expect_oid = git_sha(1, \$raw)->hexdigest;
	my $rewritten = _replace($self, $old_mime, $new_mime, \$raw) or return;
	my $need_reindex = $rewritten->{need_reindex};

	# just in case we have bugs in deduplication code:
	my $n = scalar(@$need_reindex);
	if ($n > 1) {
		my $list = join(', ', map {
					"$_->{num}: <$_->{mid}>"
				} @$need_reindex);
		warn <<"";
W: rewritten $n messages matching content of original message (expected: 1).
W: possible bug in public-inbox, NNTP article IDs and Message-IDs follow:
W: $list

	}

	# make sure we really got the OID:
	my ($blob, $type, $bytes) = $self->git->check($expect_oid);
	$blob eq $expect_oid or die "BUG: $expect_oid not found after replace";

	# don't leak FDs to Xapian:
	$self->git->cleanup;

	# reindex modified messages:
	for my $smsg (@$need_reindex) {
		my $new_smsg = bless {
			blob => $blob,
			num => $smsg->{num},
			mid => $smsg->{mid},
		}, 'PublicInbox::Smsg';
		my $sync = { autime => $smsg->{ds}, cotime => $smsg->{ts} };
		$new_smsg->populate($new_mime, $sync);
		$new_smsg->set_bytes($raw, $bytes);
		do_idx($self, $new_mime, $new_smsg);
	}
	$rewritten->{rewrites};
}

sub last_epoch_commit ($$;$) {
	my ($self, $i, $cmt) = @_;
	my $v = PublicInbox::Search::SCHEMA_VERSION();
	$self->{mm}->last_commit_xap($v, $i, $cmt);
}

sub set_last_commits ($) { # this is NOT for ExtSearchIdx
	my ($self) = @_;
	defined(my $epoch_max = $self->{epoch_max}) or return;
	my $last_commit = $self->{last_commit};
	foreach my $i (0..$epoch_max) {
		defined(my $cmt = $last_commit->[$i]) or next;
		$last_commit->[$i] = undef;
		last_epoch_commit($self, $i, $cmt);
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
	my $shards = $self->{idx_shards};
	if ($shards) {
		my $dbh = $self->{mm}->{dbh} if $self->{mm};

		# SQLite msgmap data is second in importance
		$dbh->commit if $dbh;
		eval { $dbh->do('PRAGMA optimize') };

		# SQLite overview is third
		$self->{oidx}->commit_lazy;

		# Now deal with Xapian

		# start commit_txn_lazy asynchronously on all parallel shards
		# (non-parallel waits here)
		$_->ipc_do('commit_txn_lazy') for @$shards;

		# transactions started on parallel shards,
		# wait for them by issuing an echo command (echo can only
		# run after commit_txn_lazy is done)
		if ($wait && $self->{parallel}) {
			my $i = 0;
			for my $shard (@$shards) {
				my $echo = $shard->ipc_do('echo', $i);
				$echo == $i or die <<"";
shard[$i] bad echo:$echo != $i waiting for txn commit

				++$i;
			}
		}

		my $midx = $self->{midx}; # misc index
		if ($midx) {
			$midx->commit_txn;
			$PublicInbox::Search::X{CLOEXEC_UNSET} and
				$self->git->cleanup;
		}

		# last_commit is special, don't commit these until
		# Xapian shards are done:
		$dbh->begin_work if $dbh;
		set_last_commits($self);
		if ($dbh) {
			$dbh->commit;
			$dbh->begin_work;
		}
	}
	$self->{total_bytes} += $self->{transact_bytes};
	$self->{transact_bytes} = 0;
}

# issue a write barrier to ensure all data is visible to other processes
# and read-only ops.  Order of data importance is: git > SQLite > Xapian
# public
sub barrier { checkpoint($_[0], 1) };

# true if locked and active
sub active { !!$_[0]->{im} }

# public
sub done {
	my ($self) = @_;
	my $err = '';
	if (my $im = delete $self->{im}) {
		eval { $im->done }; # PublicInbox::Import::done
		$err .= "import done: $@\n" if $@;
	}
	if (!$err) {
		eval { checkpoint($self) };
		$err .= "checkpoint: $@\n" if $@;
	}
	if (my $mm = delete $self->{mm}) {
		my $m = $err ? 'rollback' : 'commit';
		eval { $mm->{dbh}->$m };
		$err .= "msgmap $m: $@\n" if $@;
	}
	if ($self->{oidx} && $self->{oidx}->{dbh} && $err) {
		eval { $self->{oidx}->rollback_lazy };
		$err .= "overview rollback: $@\n" if $@;
	}

	my $shards = delete $self->{idx_shards};
	if ($shards) {
		for (@$shards) {
			eval { $_->shard_close };
			$err .= "shard close: $@\n" if $@;
		}
	}
	eval { $self->{oidx}->dbh_close };
	$err .= "over close: $@\n" if $@;
	delete $self->{midx};
	my $nbytes = $self->{total_bytes};
	$self->{total_bytes} = 0;
	$self->lock_release(!!$nbytes) if $shards;
	$self->git->cleanup;
	die $err if $err;
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
			my $dir = $self->{mg}->add_epoch(++$self->{epoch_max});
			my $git = PublicInbox::Git->new($dir);
			return $self->import_init($git, 0);
		}
	}
	my $epoch = 0;
	my $max;
	my $latest = $self->{ibx}->git_dir_latest(\$max);
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
	my $dir = $self->{mg}->add_epoch($epoch);
	$self->import_init(PublicInbox::Git->new($dir), 0);
}

sub import_init {
	my ($self, $git, $packed_bytes, $tmp) = @_;
	my $im = PublicInbox::Import->new($git, undef, undef, $self->{ibx});
	$im->{bytes_added} = int($packed_bytes / $PACKING_FACTOR);
	$im->{lock_path} = undef;
	$im->{path_type} = 'v2';
	$self->{im} = $im unless $tmp;
	$im;
}

# XXX experimental
sub diff ($$$) {
	my ($mid, $cur, $new) = @_;

	my $ah = File::Temp->new(TEMPLATE => 'email-cur-XXXX', TMPDIR => 1);
	print $ah $cur->as_string or die "print: $!";
	$ah->flush or die "flush: $!";
	PublicInbox::Import::drop_unwanted_headers($new);
	my $bh = File::Temp->new(TEMPLATE => 'email-new-XXXX', TMPDIR => 1);
	print $bh $new->as_string or die "print: $!";
	$bh->flush or die "flush: $!";
	my $cmd = [ qw(diff -u), $ah->filename, $bh->filename ];
	print STDERR "# MID conflict <$mid>\n";
	my $pid = spawn($cmd, undef, { 1 => 2 });
	waitpid($pid, 0) == $pid or die "diff did not finish";
}

sub get_blob ($$) {
	my ($self, $smsg) = @_;
	if (my $im = $self->{im}) {
		my $msg = $im->cat_blob($smsg->{blob});
		return $msg if $msg;
	}
	# older message, should be in alternates
	$self->{ibx}->msg_by_smsg($smsg);
}

sub content_exists ($$$) {
	my ($self, $mime, $mid) = @_;
	my $oidx = $self->{oidx};
	my $chashes = content_hashes($mime);
	my ($id, $prev);
	while (my $smsg = $oidx->next_by_mid($mid, \$id, \$prev)) {
		my $msg = get_blob($self, $smsg);
		if (!defined($msg)) {
			warn "broken smsg for $mid\n";
			next;
		}
		my $cur = PublicInbox::Eml->new($msg);
		return 1 if content_matches($chashes, $cur);

		# XXX DEBUG_DIFF is experimental and may be removed
		diff($mid, $cur, $mime) if $ENV{DEBUG_DIFF};
	}
	undef;
}

sub atfork_child {
	my ($self) = @_;
	if (my $older_siblings = $self->{idx_shards}) {
		$_->ipc_sibling_atfork_child for @$older_siblings;
	}
	if (my $im = $self->{im}) {
		$im->atfork_child;
	}
	die "BUG: unexpected mm" if $self->{mm};
}

sub reindex_checkpoint ($$) {
	my ($self, $sync) = @_;

	$self->git->async_wait_all;
	$self->update_last_commit($sync);
	${$sync->{need_checkpoint}} = 0;
	my $mm_tmp = $sync->{mm_tmp};
	$mm_tmp->atfork_prepare if $mm_tmp;
	die 'BUG: {im} during reindex' if $self->{im};
	if ($self->{ibx_map} && !$sync->{checkpoint_unlocks}) {
		checkpoint($self, 1); # no need to release lock on pure index
	} else {
		$self->done; # release lock
	}

	if (my $pr = $sync->{-regen_fmt} ? $sync->{-opt}->{-progress} : undef) {
		$pr->(sprintf($sync->{-regen_fmt}, ${$sync->{nr}}));
	}

	# allow -watch or -mda to write...
	$self->idx_init($sync->{-opt}); # reacquire lock
	if (my $intvl = $sync->{check_intvl}) { # eidx
		$sync->{next_check} = PublicInbox::DS::now() + $intvl;
	}
	$mm_tmp->atfork_parent if $mm_tmp;
}

sub index_finalize ($$) {
	my ($arg, $index) = @_;
	++$arg->{self}->{nidx};
	if (defined(my $cur = $arg->{cur_cmt})) {
		${$arg->{latest_cmt}} = $cur;
	} elsif ($index) {
		die 'BUG: {cur_cmt} missing';
	} # else { unindexing @leftovers doesn't set {cur_cmt}
}

sub index_oid { # cat_async callback
	my ($bref, $oid, $type, $size, $arg) = @_;
	is_bad_blob($oid, $type, $size, $arg->{oid}) and
		return index_finalize($arg, 1); # size == 0 purged returns here
	my $self = $arg->{self};
	local $self->{current_info} = "$self->{current_info} $oid";
	my ($num, $mid0);
	my $eml = PublicInbox::Eml->new($$bref);
	my $mids = mids($eml);
	my $chash = content_hash($eml);

	if (scalar(@$mids) == 0) {
		warn "E: $oid has no Message-ID, skipping\n";
		return;
	}

	# {unindexed} is unlikely
	if (my $unindexed = $arg->{unindexed}) {
		my $oidbin = pack('H*', $oid);
		my $u = $unindexed->{$oidbin};
		($num, $mid0) = splice(@$u, 0, 2) if $u;
		if (defined $num) {
			$self->{mm}->mid_set($num, $mid0);
			if (scalar(@$u) == 0) { # done with current OID
				delete $unindexed->{$oidbin};
				delete($arg->{unindexed}) if !keys(%$unindexed);
			}
		}
	}
	if (!defined($num)) { # reuse if reindexing (or duplicates)
		my $oidx = $self->{oidx};
		for my $mid (@$mids) {
			($num, $mid0) = $oidx->num_mid0_for_oid($oid, $mid);
			last if defined $num;
		}
	}
	$mid0 //= do { # is this a number we got before?
		$num = $arg->{mm_tmp}->num_for($mids->[0]);
		defined($num) ? $mids->[0] : undef;
	};
	if (!defined($num)) {
		for (my $i = $#$mids; $i >= 1; $i--) {
			$num = $arg->{mm_tmp}->num_for($mids->[$i]);
			if (defined($num)) {
				$mid0 = $mids->[$i];
				last;
			}
		}
	}
	if (defined($num)) {
		$arg->{mm_tmp}->num_delete($num);
	} else { # never seen
		$num = $self->{mm}->mid_insert($mids->[0]);
		if (defined($num)) {
			$mid0 = $mids->[0];
		} else { # rare, try the rest of them, backwards
			for (my $i = $#$mids; $i >= 1; $i--) {
				$num = $self->{mm}->mid_insert($mids->[$i]);
				if (defined($num)) {
					$mid0 = $mids->[$i];
					last;
				}
			}
		}
	}
	if (!defined($num)) {
		warn "E: $oid <", join('> <', @$mids), "> is a duplicate\n";
		return;
	}
	++${$arg->{nr}};
	my $smsg = bless {
		num => $num,
		blob => $oid,
		mid => $mid0,
	}, 'PublicInbox::Smsg';
	$smsg->populate($eml, $arg);
	$smsg->set_bytes($$bref, $size);
	if (do_idx($self, $eml, $smsg)) {
		${$arg->{need_checkpoint}} = 1;
	}
	index_finalize($arg, 1);
}

# only update last_commit for $i on reindex iff newer than current
sub update_last_commit {
	my ($self, $sync, $stk) = @_;
	my $unit = $sync->{unit} // return;
	my $latest_cmt = $stk ? $stk->{latest_cmt} : ${$sync->{latest_cmt}};
	defined($latest_cmt) or return;
	my $last = last_epoch_commit($self, $unit->{epoch});
	if (defined $last && is_ancestor($self->git, $last, $latest_cmt)) {
		my @cmd = (qw(rev-list --count), "$last..$latest_cmt");
		chomp(my $n = $unit->{git}->qx(@cmd));
		return if $n ne '' && $n == 0;
	}
	# don't rewind if --{since,until,before,after} are in use
	return if (defined($last) &&
			grep(defined, @{$sync->{-opt}}{qw(since until)}) &&
			is_ancestor($self->git, $latest_cmt, $last));

	last_epoch_commit($self, $unit->{epoch}, $latest_cmt);
}

sub last_commits {
	my ($self, $sync) = @_;
	my $heads = [];
	for (my $i = $sync->{epoch_max}; $i >= 0; $i--) {
		$heads->[$i] = last_epoch_commit($self, $i);
	}
	$heads;
}

# returns a revision range for git-log(1)
sub log_range ($$$) {
	my ($sync, $unit, $tip) = @_;
	my $opt = $sync->{-opt};
	my $pr = $opt->{-progress} if (($opt->{verbose} || 0) > 1);
	my $i = $unit->{epoch};
	my $cur = $sync->{ranges}->[$i] or do {
		$pr->("$i.git indexing all of $tip\n") if $pr;
		return $tip; # all of it
	};

	# fast equality check to avoid (v)fork+execve overhead
	if ($cur eq $tip) {
		$sync->{ranges}->[$i] = undef;
		return;
	}

	my $range = "$cur..$tip";
	$pr->("$i.git checking contiguity... ") if $pr;
	my $git = $unit->{git};
	if (is_ancestor($sync->{self}->git, $cur, $tip)) { # common case
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
reindexing $git->{git_dir}
starting at $range

		# $cur^0 may no longer exist if pruned by git
		if ($git->qx(qw(rev-parse -q --verify), "$cur^0")) {
			$unit->{unindex_range} = "$base..$cur";
		} elsif ($base && $git->qx(qw(rev-parse -q --verify), $base)) {
			$unit->{unindex_range} = "$base..";
		} else {
			warn "W: unable to unindex before $range\n";
		}
	}
	$range;
}

# overridden by ExtSearchIdx
sub artnum_max { $_[0]->{mm}->num_highwater }

sub sync_prepare ($$) {
	my ($self, $sync) = @_;
	$sync->{ranges} = sync_ranges($self, $sync);
	my $pr = $sync->{-opt}->{-progress};
	my $regen_max = 0;
	my $head = $sync->{ibx}->{ref_head} || 'HEAD';
	my $pfx;
	if ($pr) {
		($pfx) = ($sync->{ibx}->{inboxdir} =~ m!([^/]+)\z!g);
		$pfx //= $sync->{ibx}->{inboxdir};
	}

	my $reindex_heads;
	if ($self->{ibx_map}) {
		# ExtSearchIdx won't index messages unless they're in
		# over.sqlite3 for a given inbox, so don't read beyond
		# what's in the per-inbox index.
		$reindex_heads = [];
		my $v = PublicInbox::Search::SCHEMA_VERSION;
		my $mm = $sync->{ibx}->mm;
		for my $i (0..$sync->{epoch_max}) {
			$reindex_heads->[$i] = $mm->last_commit_xap($v, $i);
		}
	} elsif ($sync->{reindex}) { # V2 inbox
		# reindex stops at the current heads and we later
		# rerun index_sync without {reindex}
		$reindex_heads = $self->last_commits($sync);
	}
	if ($sync->{max_size} = $sync->{-opt}->{max_size}) {
		$sync->{index_oid} = $self->can('index_oid');
	}
	my $git_pfx = "$sync->{ibx}->{inboxdir}/git";
	for (my $i = $sync->{epoch_max}; $i >= 0; $i--) {
		my $git_dir = "$git_pfx/$i.git";
		-d $git_dir or next; # missing epochs are fine
		my $git = PublicInbox::Git->new($git_dir);
		my $unit = { git => $git, epoch => $i };
		my $tip;
		if ($reindex_heads) {
			$tip = $head = $reindex_heads->[$i] or next;
		} else {
			$tip = $git->qx(qw(rev-parse -q --verify), $head);
			next if $?; # new repo
			chomp $tip;
		}
		my $range = log_range($sync, $unit, $tip) or next;
		# can't use 'rev-list --count' if we use --diff-filter
		$pr->("$pfx $i.git counting $range ... ") if $pr;
		# Don't bump num_highwater on --reindex by using {D}.
		# We intentionally do NOT use {D} in the non-reindex case
		# because we want NNTP article number gaps from unindexed
		# messages to show up in mirrors, too.
		$sync->{D} //= $sync->{reindex} ? {} : undef; # OID_BIN => NR
		my $stk = log2stack($sync, $git, $range);
		return 0 if $sync->{quit};
		my $nr = $stk ? $stk->num_records : 0;
		$pr->("$nr\n") if $pr;
		$unit->{stack} = $stk; # may be undef
		unshift @{$sync->{todo}}, $unit;
		$regen_max += $nr;
	}
	return 0 if $sync->{quit};

	# XXX this should not happen unless somebody bypasses checks in
	# our code and blindly injects "d" file history into git repos
	if (my @leftovers = keys %{delete($sync->{D}) // {}}) {
		warn('W: unindexing '.scalar(@leftovers)." leftovers\n");
		local $self->{current_info} = 'leftover ';
		my $unindex_oid = $self->can('unindex_oid');
		for my $oid (@leftovers) {
			last if $sync->{quit};
			$oid = unpack('H*', $oid);
			my $req = { %$sync, oid => $oid };
			$self->git->cat_async($oid, $unindex_oid, $req);
		}
		$self->git->async_wait_all;
	}
	return 0 if $sync->{quit};
	if (!$regen_max) {
		$sync->{-regen_fmt} = "%u/?\n";
		return 0;
	}

	# reindex should NOT see new commits anymore, if we do,
	# it's a problem and we need to notice it via die()
	my $pad = length($regen_max) + 1;
	$sync->{-regen_fmt} = "% ${pad}u/$regen_max\n";
	$sync->{nr} = \(my $nr = 0);
	return -1 if $sync->{reindex};
	$regen_max + $self->artnum_max || 0;
}

sub unindex_oid_aux ($$$) {
	my ($self, $oid, $mid) = @_;
	my @removed = $self->{oidx}->remove_oid($oid, $mid);
	return unless $self->{-need_xapian};
	for my $num (@removed) {
		idx_shard($self, $num)->ipc_do('xdb_remove', $num);
	}
}

sub unindex_oid ($$;$) { # git->cat_async callback
	my ($bref, $oid, $type, $size, $arg) = @_;
	is_bad_blob($oid, $type, $size, $arg->{oid}) and
		return index_finalize($arg, 0);
	my $self = $arg->{self};
	local $self->{current_info} = "$self->{current_info} $oid";
	my $unindexed = $arg->{in_unindex} ? $arg->{unindexed} : undef;
	my $mm = $self->{mm};
	my $mids = mids(PublicInbox::Eml->new($bref));
	undef $$bref;
	my $oidx = $self->{oidx};
	foreach my $mid (@$mids) {
		my %gone;
		my ($id, $prev);
		while (my $smsg = $oidx->next_by_mid($mid, \$id, \$prev)) {
			$gone{$smsg->{num}} = 1 if $oid eq $smsg->{blob};
		}
		my $n = scalar(keys(%gone)) or next;
		if ($n > 1) {
			warn "BUG: multiple articles linked to $oid\n",
				join(',',sort keys %gone), "\n";
		}
		# reuse (num => mid) mapping in ascending numeric order
		for my $num (sort { $a <=> $b } keys %gone) {
			$num += 0;
			if ($unindexed) {
				my $mid0 = $mm->mid_for($num);
				my $oidbin = pack('H*', $oid);
				push @{$unindexed->{$oidbin}}, $num, $mid0;
			}
			$mm->num_delete($num);
		}
		unindex_oid_aux($self, $oid, $mid);
	}
	index_finalize($arg, 0);
}

sub git { $_[0]->{ibx}->git }

# this is rare, it only happens when we get discontiguous history in
# a mirror because the source used -purge or -edit
sub unindex_todo ($$$) {
	my ($self, $sync, $unit) = @_;
	my $unindex_range = delete($unit->{unindex_range}) // return;
	my $unindexed = $sync->{unindexed} //= {}; # $oidbin => [$num, $mid0]
	my $before = scalar keys %$unindexed;
	# order does not matter, here:
	my $fh = $unit->{git}->popen(qw(log --raw -r --no-notes --no-color
				--no-abbrev --no-renames), $unindex_range);
	local $sync->{in_unindex} = 1;
	my $unindex_oid = $self->can('unindex_oid');
	while (<$fh>) {
		/\A:\d{6} 100644 $OID ($OID) [AM]\tm$/o or next;
		$self->git->cat_async($1, $unindex_oid, { %$sync, oid => $1 });
	}
	close $fh or die "git log failed: \$?=$?";
	$self->git->async_wait_all;

	return unless $sync->{-opt}->{prune};
	my $after = scalar keys %$unindexed;
	return if $before == $after;

	# ensure any blob can not longer be accessed via dumb HTTP
	run_die(['git', "--git-dir=$unit->{git}->{git_dir}",
		qw(-c gc.reflogExpire=now gc --prune=all --quiet)]);
}

sub sync_ranges ($$) {
	my ($self, $sync) = @_;
	my $reindex = $sync->{reindex};
	return $self->last_commits($sync) unless $reindex;
	return [] if ref($reindex) ne 'HASH';

	my $ranges = $reindex->{from}; # arrayref;
	if (ref($ranges) ne 'ARRAY') {
		die 'BUG: $reindex->{from} not an ARRAY';
	}
	$ranges;
}

sub index_xap_only { # git->cat_async callback
	my ($bref, $oid, $type, $size, $smsg) = @_;
	my $self = delete $smsg->{self};
	my $idx = idx_shard($self, $smsg->{num});
	$idx->index_eml(PublicInbox::Eml->new($bref), $smsg);
	$self->{transact_bytes} += $smsg->{bytes};
}

sub index_xap_step ($$$;$) {
	my ($self, $sync, $beg, $step) = @_;
	my $end = $sync->{art_end};
	return if $beg > $end; # nothing to do

	$step //= $self->{shards};
	my $ibx = $self->{ibx};
	if (my $pr = $sync->{-opt}->{-progress}) {
		$pr->("Xapian indexlevel=$ibx->{indexlevel} ".
			"$beg..$end (% $step)\n");
	}
	for (my $num = $beg; $num <= $end; $num += $step) {
		last if $sync->{quit};
		my $smsg = $ibx->over->get_art($num) or next;
		$smsg->{self} = $self;
		$ibx->git->cat_async($smsg->{blob}, \&index_xap_only, $smsg);
		if ($self->{transact_bytes} >= $self->{batch_bytes}) {
			${$sync->{nr}} = $num;
			reindex_checkpoint($self, $sync);
		}
	}
}

sub index_todo ($$$) {
	my ($self, $sync, $unit) = @_;
	return if $sync->{quit};
	unindex_todo($self, $sync, $unit);
	my $stk = delete($unit->{stack}) or return;
	my $all = $self->git;
	my $index_oid = $self->can('index_oid');
	my $unindex_oid = $self->can('unindex_oid');
	my $pfx;
	if ($unit->{git}->{git_dir} =~ m!/([^/]+)/git/([0-9]+\.git)\z!) {
		$pfx = "$1 $2"; # v2
	} else { # v1
		($pfx) = ($unit->{git}->{git_dir} =~ m!/([^/]+)\z!g);
		$pfx //= $unit->{git}->{git_dir};
	}
	local $self->{current_info} = "$pfx ";
	local $sync->{latest_cmt} = \(my $latest_cmt);
	local $sync->{unit} = $unit;
	while (my ($f, $at, $ct, $oid, $cmt) = $stk->pop_rec) {
		if ($sync->{quit}) {
			warn "waiting to quit...\n";
			$all->async_wait_all;
			$self->update_last_commit($sync);
			return;
		}
		my $req = {
			%$sync,
			autime => $at,
			cotime => $ct,
			oid => $oid,
			cur_cmt => $cmt
		};
		if ($f eq 'm') {
			if ($sync->{max_size}) {
				$all->check_async($oid, \&check_size, $req);
			} else {
				$all->cat_async($oid, $index_oid, $req);
			}
		} elsif ($f eq 'd') {
			$all->cat_async($oid, $unindex_oid, $req);
		}
		if (${$sync->{need_checkpoint}}) {
			reindex_checkpoint($self, $sync);
		}
	}
	$all->async_wait_all;
	$self->update_last_commit($sync, $stk);
}

sub xapian_only {
	my ($self, $opt, $sync, $art_beg) = @_;
	my $seq = $opt->{'sequential-shard'};
	$art_beg //= 0;
	local $self->{parallel} = 0 if $seq;
	$self->idx_init($opt); # acquire lock
	if (my $art_end = $self->{ibx}->mm->max) {
		$sync //= {
			need_checkpoint => \(my $bool = 0),
			-opt => $opt,
			self => $self,
			nr => \(my $nr = 0),
			-regen_fmt => "%u/?\n",
		};
		$sync->{art_end} = $art_end;
		if ($seq || !$self->{parallel}) {
			my $shard_end = $self->{shards} - 1;
			for my $i (0..$shard_end) {
				last if $sync->{quit};
				index_xap_step($self, $sync, $art_beg + $i);
				if ($i != $shard_end) {
					reindex_checkpoint($self, $sync);
				}
			}
		} else { # parallel (maybe)
			index_xap_step($self, $sync, $art_beg, 1);
		}
	}
	$self->git->async_wait_all;
	$self->{ibx}->cleanup;
	$self->done;
}

# public, called by public-inbox-index
sub index_sync {
	my ($self, $opt) = @_;
	$opt //= {};
	return xapian_only($self, $opt) if $opt->{xapian_only};

	my $epoch_max;
	my $latest = $self->{ibx}->git_dir_latest(\$epoch_max) // return;
	if ($opt->{'fast-noop'}) { # nanosecond (st_ctim) comparison
		use Time::HiRes qw(stat);
		if (my @mm = stat("$self->{ibx}->{inboxdir}/msgmap.sqlite3")) {
			my $c = $mm[10]; # 10 = ctime (nsec NV)
			my @hd = stat("$latest/refs/heads");
			my @pr = stat("$latest/packed-refs");
			return if $c > ($hd[10] // 0) && $c > ($pr[10] // 0);
		}
	}

	my $pr = $opt->{-progress};
	my $seq = $opt->{'sequential-shard'};
	my $art_beg; # the NNTP article number we start xapian_only at
	my $idxlevel = $self->{ibx}->{indexlevel};
	local $self->{ibx}->{indexlevel} = 'basic' if $seq;

	$self->idx_init($opt); # acquire lock
	$self->{mg}->fill_alternates;
	$self->{oidx}->rethread_prepare($opt);
	my $sync = {
		need_checkpoint => \(my $bool = 0),
		reindex => $opt->{reindex},
		-opt => $opt,
		self => $self,
		ibx => $self->{ibx},
		epoch_max => $epoch_max,
	};
	my $quit = PublicInbox::SearchIdx::quit_cb($sync);
	local $SIG{QUIT} = $quit;
	local $SIG{INT} = $quit;
	local $SIG{TERM} = $quit;

	if (sync_prepare($self, $sync)) {
		# tmp_clone seems to fail if inside a transaction, so
		# we rollback here (because we opened {mm} for reading)
		# Note: we do NOT rely on DBI transactions for atomicity;
		# only for batch performance.
		$self->{mm}->{dbh}->rollback;
		$self->{mm}->{dbh}->begin_work;
		$sync->{mm_tmp} =
			$self->{mm}->tmp_clone($self->{ibx}->{inboxdir});

		# xapian_only works incrementally w/o --reindex
		if ($seq && !$opt->{reindex}) {
			$art_beg = $sync->{mm_tmp}->max || -1;
			$art_beg++;
		}
	}
	# work forwards through history
	index_todo($self, $sync, $_) for @{delete($sync->{todo}) // []};
	$self->{oidx}->rethread_done($opt) unless $sync->{quit};
	$self->done;

	if (my $nr = $sync->{nr}) {
		my $pr = $sync->{-opt}->{-progress};
		$pr->('all.git '.sprintf($sync->{-regen_fmt}, $$nr)) if $pr;
	}

	my $quit_warn;
	# deal with Xapian shards sequentially
	if ($seq && delete($sync->{mm_tmp})) {
		if ($sync->{quit}) {
			$quit_warn = 1;
		} else {
			$self->{ibx}->{indexlevel} = $idxlevel;
			xapian_only($self, $opt, $sync, $art_beg);
			$quit_warn = 1 if $sync->{quit};
		}
	}

	# --reindex on the command-line
	if (!$sync->{quit} && $opt->{reindex} &&
			!ref($opt->{reindex}) && $idxlevel ne 'basic') {
		$self->lock_acquire;
		my $s0 = PublicInbox::SearchIdx->new($self->{ibx}, 0, 0);
		if (my $xdb = $s0->idx_acquire) {
			my $n = $xdb->get_metadata('has_threadid');
			$xdb->set_metadata('has_threadid', '1') if $n ne '1';
		}
		$s0->idx_release;
		$self->lock_release;
	}

	# reindex does not pick up new changes, so we rerun w/o it:
	if ($opt->{reindex} && !$sync->{quit} &&
			!grep(defined, @$opt{qw(since until)})) {
		my %again = %$opt;
		$sync = undef;
		delete @again{qw(rethread reindex -skip_lock)};
		index_sync($self, \%again);
		$opt->{quit} = $again{quit}; # propagate to caller
	}
	warn <<EOF if $quit_warn;
W: interrupted, --xapian-only --reindex required upon restart
EOF
}

sub ipc_atfork_child {
	my ($self) = @_;
	if (my $lei = delete $self->{lei}) {
		$lei->_lei_atfork_child;
		my $pkt_op_p = delete $lei->{pkt_op_p};
		close($pkt_op_p->{op_p});
	}
	$self->SUPER::ipc_atfork_child;
}

1;
