# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# This interface wraps and mimics PublicInbox::Import
# Used to write to V2 inboxes (see L<public-inbox-v2-format(5)>).
package PublicInbox::V2Writable;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock);
use PublicInbox::SearchIdxShard;
use PublicInbox::Eml;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::MID qw(mids references);
use PublicInbox::ContentHash qw(content_hash content_digest);
use PublicInbox::InboxWritable;
use PublicInbox::OverIdx;
use PublicInbox::Msgmap;
use PublicInbox::Spawn qw(spawn popen_rd);
use PublicInbox::SearchIdx;
use PublicInbox::MultiMidQueue;
use IO::Handle; # ->autoflush
use File::Temp qw(tempfile);

# an estimate of the post-packed size to the raw uncompressed size
my $PACKING_FACTOR = 0.4;

# SATA storage lags behind what CPUs are capable of, so relying on
# nproc(1) can be misleading and having extra Xapian shards is a
# waste of FDs and space.  It can also lead to excessive IO latency
# and slow things down.  Users on NVME or other fast storage can
# use the NPROC env or switches in our script/public-inbox-* programs
# to increase Xapian shards
our $NPROC_MAX_DEFAULT = 4;

sub detect_nproc () {
	for my $nproc (qw(nproc gnproc)) { # GNU coreutils nproc
		`$nproc 2>/dev/null` =~ /^(\d+)$/ and return $1;
	}

	# getconf(1) is POSIX, but *NPROCESSORS* vars are not
	for (qw(_NPROCESSORS_ONLN NPROCESSORS_ONLN)) {
		`getconf $_ 2>/dev/null` =~ /^(\d+)$/ and return $1;
	}

	# should we bother with `sysctl hw.ncpu`?  Those only give
	# us total processor count, not online processor count.
	undef
}

sub nproc_shards ($) {
	my ($creat_opt) = @_;
	my $n = $creat_opt->{nproc} if ref($creat_opt) eq 'HASH';
	$n //= $ENV{NPROC};
	if (!$n) {
		# assume 2 cores if not detectable or zero
		state $NPROC_DETECTED = detect_nproc() || 2;
		$n = $NPROC_DETECTED;
		$n = $NPROC_MAX_DEFAULT if $n > $NPROC_MAX_DEFAULT;
	}

	# subtract for the main process and git-fast-import
	$n -= 1;
	$n < 1 ? 1 : $n;
}

sub count_shards ($) {
	my ($self) = @_;
	my $n = 0;
	my $xpfx = $self->{xpfx};

	# always load existing shards in case core count changes:
	# Also, shard count may change while -watch is running
	# due to "xcpdb --reshard"
	if (-d $xpfx) {
		my $XapianDatabase;
		foreach my $shard (<$xpfx/*>) {
			-d $shard && $shard =~ m!/[0-9]+\z! or next;
			$XapianDatabase //= do {
				require PublicInbox::Search;
				PublicInbox::Search::load_xapian();
				$PublicInbox::Search::X{Database};
			};
			eval {
				$XapianDatabase->new($shard)->close;
				$n++;
			};
		}
	}
	$n;
}

sub new {
	# $creat may be any true value, or 0/undef.  A hashref is true,
	# and $creat->{nproc} may be set to an integer
	my ($class, $v2ibx, $creat) = @_;
	$v2ibx = PublicInbox::InboxWritable->new($v2ibx);
	my $dir = $v2ibx->assert_usable_dir;
	unless (-d $dir) {
		if ($creat) {
			require File::Path;
			File::Path::mkpath($dir);
		} else {
			die "$dir does not exist\n";
		}
	}
	$v2ibx->umask_prepare;

	my $xpfx = "$dir/xap" . PublicInbox::Search::SCHEMA_VERSION;
	my $self = {
		-inbox => $v2ibx,
		im => undef, #  PublicInbox::Import
		parallel => 1,
		transact_bytes => 0,
		total_bytes => 0,
		current_info => '',
		xpfx => $xpfx,
		over => PublicInbox::OverIdx->new("$xpfx/over.sqlite3", 1),
		lock_path => "$dir/inbox.lock",
		# limit each git repo (epoch) to 1GB or so
		rotate_bytes => int((1024 * 1024 * 1024) / $PACKING_FACTOR),
		last_commit => [], # git repo -> commit
	};
	$self->{shards} = count_shards($self) || nproc_shards($creat);
	$self->{index_max_size} = $v2ibx->{index_max_size};
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
	my ($self, $eml, $check_cb) = @_;
	$self->{-inbox}->with_umask(\&_add, $self, $eml, $check_cb);
}

# indexes a message, returns true if checkpointing is needed
sub do_idx ($$$$) {
	my ($self, $msgref, $mime, $smsg) = @_;
	$smsg->{bytes} = $smsg->{raw_bytes} +
			PublicInbox::SearchIdx::crlf_adjust($$msgref);
	$self->{over}->add_overview($mime, $smsg);
	my $idx = idx_shard($self, $smsg->{num} % $self->{shards});
	$idx->index_raw($msgref, $mime, $smsg);
	my $n = $self->{transact_bytes} += $smsg->{raw_bytes};
	$n >= ($PublicInbox::SearchIdx::BATCH_BYTES * $self->{shards});
}

sub _add {
	my ($self, $mime, $check_cb) = @_;

	# spam check:
	if ($check_cb) {
		$mime = $check_cb->($mime, $self->{-inbox}) or return;
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

	my $msgref = delete $smsg->{-raw_email};
	if (do_idx($self, $msgref, $mime, $smsg)) {
		$self->checkpoint;
	}

	$cmt;
}

sub v2_num_for {
	my ($self, $mime) = @_;
	my $mids = mids($mime->header_obj);
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
		my $altid = $self->{-inbox}->{altid};
		if ($altid && grep(/:file=msgmap\.sqlite3\z/, @$altid)) {
			my $num = $self->{mm}->num_for($mid);

			if (defined $num && !$self->{over}->get_art($num)) {
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
	my ($self, $mime) = @_;

	my $hdr = $mime->header_obj;
	my $dig = content_digest($mime);
	my $mid0 = PublicInbox::Import::digest2mid($dig, $hdr);
	my $num = $self->{mm}->mid_insert($mid0);
	unless (defined $num) {
		# it's hard to spoof the last Received: header
		my @recvd = $hdr->header_raw('Received');
		$dig->add("Received: $_") foreach (@recvd);
		$mid0 = PublicInbox::Import::digest2mid($dig, $hdr);
		$num = $self->{mm}->mid_insert($mid0);

		# fall back to a random Message-ID and give up determinism:
		until (defined($num)) {
			$dig->add(rand);
			$mid0 = PublicInbox::Import::digest2mid($dig, $hdr);
			warn "using random Message-ID <$mid0> as fallback\n";
			$num = $self->{mm}->mid_insert($mid0);
		}
	}
	PublicInbox::Import::append_mid($hdr, $mid0);
	($num, $mid0);
}

sub idx_shard {
	my ($self, $shard_i) = @_;
	$self->{idx_shards}->[$shard_i];
}

sub _idx_init { # with_umask callback
	my ($self, $opt) = @_;
	$self->lock_acquire unless $opt && $opt->{-skip_lock};
	$self->{over}->create;

	# xcpdb can change shard count while -watch is idle
	my $nshards = count_shards($self);
	$self->{shards} = $nshards if $nshards && $nshards != $self->{shards};

	# need to create all shards before initializing msgmap FD
	# idx_shards must be visible to all forked processes
	my $max = $self->{shards} - 1;
	my $idx = $self->{idx_shards} = [];
	push @$idx, PublicInbox::SearchIdxShard->new($self, $_) for (0..$max);

	# Now that all subprocesses are up, we can open the FDs
	# for SQLite:
	my $mm = $self->{mm} = PublicInbox::Msgmap->new_file(
		"$self->{-inbox}->{inboxdir}/msgmap.sqlite3", 1);
	$mm->{dbh}->begin_work;
}

# idempotent
sub idx_init {
	my ($self, $opt) = @_;
	return if $self->{idx_shards};
	my $ibx = $self->{-inbox};

	# do not leak read-only FDs to child processes, we only have these
	# FDs for duplicate detection so they should not be
	# frequently activated.
	# delete @$ibx{qw(git mm search)};
	delete $ibx->{$_} foreach (qw(git mm search));

	$self->{parallel} = 0 if ($ibx->{indexlevel}//'') eq 'basic';
	if ($self->{parallel}) {
		pipe(my ($r, $w)) or die "pipe failed: $!";
		# pipe for barrier notifications doesn't need to be big,
		# 1031: F_SETPIPE_SZ
		fcntl($w, 1031, 4096) if $^O eq 'linux';
		$self->{bnote} = [ $r, $w ];
		$w->autoflush(1);
	}

	$ibx->umask_prepare;
	$ibx->with_umask(\&_idx_init, $self, $opt);
}

# returns an array mapping [ epoch => latest_commit ]
# latest_commit may be undef if nothing was done to that epoch
# $replace_map = { $object_id => $strref, ... }
sub _replace_oids ($$$) {
	my ($self, $mime, $replace_map) = @_;
	$self->done;
	my $pfx = "$self->{-inbox}->{inboxdir}/git";
	my $rewrites = []; # epoch => commit
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
	my $over = $self->{over};
	my $chashes = content_hashes($old_eml);
	my $removed = [];
	my $mids = mids($old_eml->header_obj);

	# We avoid introducing new blobs into git since the raw content
	# can be slightly different, so we do not need the user-supplied
	# message now that we have the mids and content_hash
	$old_eml = undef;
	my $mark;

	foreach my $mid (@$mids) {
		my %gone; # num => [ smsg, $mime, raw ]
		my ($id, $prev);
		while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
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
			unindex_oid_remote($self, $oid, $mid);
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
	my $r = $self->{-inbox}->with_umask(\&rewrite_internal,
						$self, $eml, $cmt_msg);
	defined($r) && defined($r->[0]) ? @$r: undef;
}

sub _replace ($$;$$) {
	my ($self, $old_eml, $new_eml, $sref) = @_;
	my $arg = [ $self, $old_eml, undef, $new_eml, $sref ];
	my $rewritten = $self->{-inbox}->with_umask(\&rewrite_internal,
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

# returns the git object_id of $fh, does not write the object to FS
sub git_hash_raw ($$) {
	my ($self, $raw) = @_;
	# grab the expected OID we have to reindex:
	pipe(my($in, $w)) or die "pipe: $!";
	my $git_dir = $self->{-inbox}->git->{git_dir};
	my $cmd = ['git', "--git-dir=$git_dir", qw(hash-object --stdin)];
	my $r = popen_rd($cmd, undef, { 0 => $in });
	print $w $$raw or die "print \$w: $!";
	close $w or die "close \$w: $!";
	local $/ = "\n";
	chomp(my $oid = <$r>);
	close $r or die "git hash-object failed: $?";
	$oid =~ /\A[a-f0-9]{40}\z/ or die "OID not expected: $oid";
	$oid;
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
	my ($old_mime, $new_mime) = @_;
	my $old = $old_mime->header_obj;
	my $new = $new_mime->header_obj;
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
	my $expect_oid = git_hash_raw($self, \$raw);
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
	my ($blob, $type, $bytes) = $self->{-inbox}->git->check($expect_oid);
	$blob eq $expect_oid or die "BUG: $expect_oid not found after replace";

	# don't leak FDs to Xapian:
	$self->{-inbox}->git->cleanup;

	# reindex modified messages:
	for my $smsg (@$need_reindex) {
		my $new_smsg = bless {
			blob => $blob,
			raw_bytes => $bytes,
			num => $smsg->{num},
			mid => $smsg->{mid},
		}, 'PublicInbox::Smsg';
		my $v2w = { autime => $smsg->{ds}, cotime => $smsg->{ts} };
		$new_smsg->populate($new_mime, $v2w);
		do_idx($self, \$raw, $new_mime, $new_smsg);
	}
	$rewritten->{rewrites};
}

sub last_epoch_commit ($$;$) {
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
		last_epoch_commit($self, $i, $cmt);
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
		defined(my $l = readline($r)) or die "EOF on barrier_wait: $!";
		$l =~ /\Abarrier (\d+)/ or die "bad line on barrier_wait: $l";
		delete $barrier->{$1} or die "bad shard[$1] on barrier wait";
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
		my $dbh = $self->{mm}->{dbh};

		# SQLite msgmap data is second in importance
		$dbh->commit;

		# SQLite overview is third
		$self->{over}->commit_lazy;

		# Now deal with Xapian
		if ($wait) {
			my $barrier = $self->barrier_init(scalar @$shards);

			# each shard needs to issue a barrier command
			$_->remote_barrier for @$shards;

			# wait for each Xapian shard
			$self->barrier_wait($barrier);
		} else {
			$_->remote_commit for @$shards;
		}

		# last_commit is special, don't commit these until
		# remote shards are done:
		$dbh->begin_work;
		set_last_commits($self);
		$dbh->commit;

		$dbh->begin_work;
	}
	$self->{total_bytes} += $self->{transact_bytes};
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
	my $shards = delete $self->{idx_shards};
	if ($shards) {
		$_->remote_close for @$shards;
	}
	$self->{over}->disconnect;
	delete $self->{bnote};
	my $nbytes = $self->{total_bytes};
	$self->{total_bytes} = 0;
	$self->lock_release(!!$nbytes) if $shards;
	$self->{-inbox}->git->cleanup;
}

sub fill_alternates ($$) {
	my ($self, $epoch) = @_;

	my $pfx = "$self->{-inbox}->{inboxdir}/git";
	my $all = "$self->{-inbox}->{inboxdir}/all.git";

	unless (-d $all) {
		PublicInbox::Import::init_bare($all);
	}
	my $info_dir = "$all/objects/info";
	my $alt = "$info_dir/alternates";
	my (%alt, $new);
	my $mode = 0644;
	if (-e $alt) {
		open(my $fh, '<', $alt) or die "open < $alt: $!\n";
		$mode = (stat($fh))[2] & 07777;

		# we assign a sort score to every alternate and favor
		# the newest (highest numbered) one when we
		my $score;
		my $other = 0; # in case admin adds non-epoch repos
		%alt = map {;
			if (m!\A\Q../../\E([0-9]+)\.git/objects\z!) {
				$score = $1 + 0;
			} else {
				$score = --$other;
			}
			$_ => $score;
		} split(/\n+/, do { local $/; <$fh> });
	}

	foreach my $i (0..$epoch) {
		my $dir = "../../git/$i.git/objects";
		if (!exists($alt{$dir}) && -d "$pfx/$i.git") {
			$alt{$dir} = $i;
			$new = 1;
		}
	}
	return unless $new;

	my ($fh, $tmp) = tempfile('alt-XXXXXXXX', DIR => $info_dir);
	print $fh join("\n", sort { $alt{$b} <=> $alt{$a} } keys %alt), "\n"
		or die "print $tmp: $!\n";
	chmod($mode, $fh) or die "fchmod $tmp: $!\n";
	close $fh or die "close $tmp $!\n";
	rename($tmp, $alt) or die "rename $tmp => $alt: $!\n";
}

sub git_init {
	my ($self, $epoch) = @_;
	my $git_dir = "$self->{-inbox}->{inboxdir}/git/$epoch.git";
	PublicInbox::Import::init_bare($git_dir);
	my @cmd = (qw/git config/, "--file=$git_dir/config",
			'include.path', '../../all.git/config');
	PublicInbox::Import::run_die(\@cmd);
	fill_alternates($self, $epoch);
	$git_dir
}

sub git_dir_latest {
	my ($self, $max) = @_;
	$$max = -1;
	my $pfx = "$self->{-inbox}->{inboxdir}/git";
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
	$im->{lock_path} = undef;
	$im->{path_type} = 'v2';
	$self->{im} = $im unless $tmp;
	$im;
}

# XXX experimental
sub diff ($$$) {
	my ($mid, $cur, $new) = @_;

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

sub content_exists ($$$) {
	my ($self, $mime, $mid) = @_;
	my $over = $self->{over};
	my $chashes = content_hashes($mime);
	my ($id, $prev);
	while (my $smsg = $over->next_by_mid($mid, \$id, \$prev)) {
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
	my $fh = delete $self->{reindex_pipe};
	close $fh if $fh;
	if (my $shards = $self->{idx_shards}) {
		$_->atfork_child foreach @$shards;
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
	return if PublicInbox::SearchIdx::too_big($self, $git, $oid);
	my $msgref = $git->cat_file($oid);
	my $mime = PublicInbox::Eml->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $chash = content_hash($mime);
	foreach my $mid (@$mids) {
		$sync->{D}->{"$mid\0$chash"} = $oid;
	}
}

sub reindex_checkpoint ($$$) {
	my ($self, $sync, $git) = @_;

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

# only for a few odd messages with multiple Message-IDs
sub reindex_oid_m ($$$$;$) {
	my ($self, $sync, $git, $oid, $regen_num) = @_;
	$self->{current_info} = "multi_mid $oid";
	my ($num, $mid0, $len);
	my $msgref = $git->cat_file($oid, \$len);
	my $mime = PublicInbox::Eml->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $chash = content_hash($mime);
	die "BUG: reindex_oid_m called for <=1 mids" if scalar(@$mids) <= 1;

	for my $mid (reverse @$mids) {
		delete($sync->{D}->{"$mid\0$chash"}) and
			die "BUG: reindex_oid should handle <$mid> delete";
	}
	my $over = $self->{over};
	for my $mid (reverse @$mids) {
		($num, $mid0) = $over->num_mid0_for_oid($oid, $mid);
		next unless defined $num;
		if (defined($regen_num) && $regen_num != $num) {
			die "BUG: regen(#$regen_num) != over(#$num)";
		}
	}
	unless (defined($num)) {
		for my $mid (reverse @$mids) {
			# is this a number we got before?
			my $n = $sync->{mm_tmp}->num_for($mid);
			next unless defined $n;
			next if defined($regen_num) && $regen_num != $n;
			($num, $mid0) = ($n, $mid);
			last;
		}
	}
	if (defined($num)) {
		$sync->{mm_tmp}->num_delete($num);
	} elsif (defined $regen_num) {
		$num = $regen_num;
		for my $mid (reverse @$mids) {
			$self->{mm}->mid_set($num, $mid) == 1 or next;
			$mid0 = $mid;
			last;
		}
		unless (defined $mid0) {
			warn "E: cannot regen #$num\n";
			return;
		}
	} else { # fixup bugs in old mirrors on reindex
		for my $mid (reverse @$mids) {
			$num = $self->{mm}->mid_insert($mid);
			next unless defined $num;
			$mid0 = $mid;
			last;
		}
		if (defined $mid0) {
			if ($sync->{reindex}) {
				warn "reindex added #$num <$mid0>\n";
			}
		} else {
			warn "E: cannot find article #\n";
			return;
		}
	}
	$sync->{nr}++;
	my $smsg = bless {
		raw_bytes => $len,
		num => $num,
		blob => $oid,
		mid => $mid0,
	}, 'PublicInbox::Smsg';
	$smsg->populate($mime, $self);
	if (do_idx($self, $msgref, $mime, $smsg)) {
		reindex_checkpoint($self, $sync, $git);
	}
}

sub check_unindexed ($$$) {
	my ($self, $num, $mid0) = @_;
	my $unindexed = $self->{unindexed} // {};
	my $n = delete($unindexed->{$mid0});
	defined $n or return;
	if ($n != $num) {
		die "BUG: unindexed $n != $num <$mid0>\n";
	} else {
		$self->{mm}->mid_set($num, $mid0);
	}
}

sub multi_mid_q_push ($$$) {
	my ($self, $sync, $oid) = @_;
	my $multi_mid = $sync->{multi_mid} //= PublicInbox::MultiMidQueue->new;
	if ($sync->{reindex}) { # no regen on reindex
		$multi_mid->push_oid($oid, $self);
	} else {
		my $num = $sync->{regen}--;
		die "BUG: ran out of article numbers" if $num <= 0;
		$multi_mid->set_oid($num, $oid, $self);
	}
}

sub reindex_oid ($$$$) {
	my ($self, $sync, $git, $oid) = @_;
	return if PublicInbox::SearchIdx::too_big($self, $git, $oid);
	my ($num, $mid0, $len);
	my $msgref = $git->cat_file($oid, \$len);
	return if $len == 0; # purged
	my $mime = PublicInbox::Eml->new($$msgref);
	my $mids = mids($mime->header_obj);
	my $chash = content_hash($mime);

	if (scalar(@$mids) == 0) {
		warn "E: $oid has no Message-ID, skipping\n";
		return;
	} elsif (scalar(@$mids) == 1) {
		my $mid = $mids->[0];

		# was the file previously marked as deleted?, skip if so
		if (delete($sync->{D}->{"$mid\0$chash"})) {
			if (!$sync->{reindex}) {
				$num = $sync->{regen}--;
				$self->{mm}->num_highwater($num);
			}
			return;
		}

		# is this a number we got before?
		$num = $sync->{mm_tmp}->num_for($mid);
		if (defined $num) {
			$mid0 = $mid;
			check_unindexed($self, $num, $mid0);
		} else {
			$num = $sync->{regen}--;
			die "BUG: ran out of article numbers" if $num <= 0;
			if ($self->{mm}->mid_set($num, $mid) != 1) {
				warn "E: unable to assign $num => <$mid>\n";
				return;
			}
			$mid0 = $mid;
		}
	} else { # multiple MIDs are a weird case:
		my $del = 0;
		for (@$mids) {
			$del += delete($sync->{D}->{"$_\0$chash"}) // 0;
		}
		if ($del) {
			unindex_oid_remote($self, $oid, $_) for @$mids;
			# do not delete from {mm_tmp}, since another
			# single-MID message may use it.
		} else { # handle them at the end:
			multi_mid_q_push($self, $sync, $oid);
		}
		return;
	}
	$sync->{mm_tmp}->mid_delete($mid0) or
		die "failed to delete <$mid0> for article #$num\n";
	$sync->{nr}++;
	my $smsg = bless {
		raw_bytes => $len,
		num => $num,
		blob => $oid,
		mid => $mid0,
	}, 'PublicInbox::Smsg';
	$smsg->populate($mime, $self);
	if (do_idx($self, $msgref, $mime, $smsg)) {
		reindex_checkpoint($self, $sync, $git);
	}
}

# only update last_commit for $i on reindex iff newer than current
sub update_last_commit ($$$$) {
	my ($self, $git, $i, $cmt) = @_;
	my $last = last_epoch_commit($self, $i);
	if (defined $last && is_ancestor($git, $last, $cmt)) {
		my @cmd = (qw(rev-list --count), "$last..$cmt");
		chomp(my $n = $git->qx(@cmd));
		return if $n ne '' && $n == 0;
	}
	last_epoch_commit($self, $i, $cmt);
}

sub git_dir_n ($$) { "$_[0]->{-inbox}->{inboxdir}/git/$_[1].git" }

sub last_commits ($$) {
	my ($self, $epoch_max) = @_;
	my $heads = [];
	for (my $i = $epoch_max; $i >= 0; $i--) {
		$heads->[$i] = last_epoch_commit($self, $i);
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
		-d $git_dir or next; # missing epochs are fine
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
		close $fh or die "git log failed: \$?=$?";
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
	my @removed = $self->{over}->remove_oid($oid, $mid);
	for my $num (@removed) {
		my $idx = idx_shard($self, $num % $self->{shards});
		$idx->remote_remove($oid, $num);
	}
}

sub unindex_oid ($$$;$) {
	my ($self, $git, $oid, $unindexed) = @_;
	my $mm = $self->{mm};
	my $msgref = $git->cat_file($oid);
	my $mime = PublicInbox::Eml->new($msgref);
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
			if ($unindexed) {
				my $mid0 = $mm->mid_for($num);
				$unindexed->{$mid0} = $num;
			}
			$mm->num_delete($num);
		}
		unindex_oid_remote($self, $oid, $mid);
	}
}

my $x40 = qr/[a-f0-9]{40}/;
sub unindex ($$$$) {
	my ($self, $sync, $git, $unindex_range) = @_;
	my $unindexed = $self->{unindexed} ||= {}; # $mid0 => $num
	my $before = scalar keys %$unindexed;
	# order does not matter, here:
	my @cmd = qw(log --raw -r
			--no-notes --no-color --no-abbrev --no-renames);
	my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $unindex_range);
	while (<$fh>) {
		/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o or next;
		unindex_oid($self, $git, $1, $unindexed);
	}
	delete $self->{reindex_pipe};
	close $fh or die "git log failed: \$?=$?";

	return unless $sync->{-opt}->{prune};
	my $after = scalar keys %$unindexed;
	return if $before == $after;

	# ensure any blob can not longer be accessed via dumb HTTP
	PublicInbox::Import::run_die(['git', "--git-dir=$git->{git_dir}",
		qw(-c gc.reflogExpire=now gc --prune=all --quiet)]);
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
	-d $git_dir or return; # missing epochs are fine
	fill_alternates($self, $i);
	my $git = PublicInbox::Git->new($git_dir);
	if (my $unindex_range = delete $sync->{unindex_range}->{$i}) {
		unindex($self, $sync, $git, $unindex_range);
	}
	defined(my $range = $sync->{ranges}->[$i]) or return;
	if (my $pr = $sync->{-opt}->{-progress}) {
		$pr->("$i.git indexing $range\n");
	}

	my @cmd = qw(log --raw -r --pretty=tformat:%H.%at.%ct
			--no-notes --no-color --no-abbrev --no-renames);
	my $fh = $self->{reindex_pipe} = $git->popen(@cmd, $range);
	my $cmt;
	while (<$fh>) {
		chomp;
		$self->{current_info} = "$i.git $_";
		if (/\A($x40)\.([0-9]+)\.([0-9]+)$/o) {
			$cmt //= $1;
			$self->{autime} = $2;
			$self->{cotime} = $3;
		} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\tm$/o) {
			reindex_oid($self, $sync, $git, $1);
		} elsif (/\A:\d{6} 100644 $x40 ($x40) [AM]\td$/o) {
			mark_deleted($self, $sync, $git, $1);
		}
	}
	close $fh or die "git log failed: \$?=$?";
	delete @$self{qw(reindex_pipe autime cotime)};
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
	$self->{over}->rethread_prepare($opt);
	my $sync = {
		D => {}, # "$mid\0$chash" => $oid
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
	my $git;
	if (my @leftovers = values %{delete $sync->{D}}) {
		$git = $self->{-inbox}->git;
		for my $oid (@leftovers) {
			$self->{current_info} = "leftover $oid";
			unindex_oid($self, $git, $oid);
		}
	}
	if (my $multi_mid = delete $sync->{multi_mid}) {
		$git //= $self->{-inbox}->git;
		my $min = $multi_mid->{min};
		my $max = $multi_mid->{max};
		if ($sync->{reindex}) {
			# we may need to create new Message-IDs if mirrors
			# were initially indexed with old versions
			for (my $i = $max; $i >= $min; $i--) {
				my $oid;
				$oid = $multi_mid->get_oid($i, $self) or next;
				next unless defined $oid;
				reindex_oid_m($self, $sync, $git, $oid);
			}
		} else { # regen on initial index
			for my $num ($min..$max) {
				my $oid;
				$oid = $multi_mid->get_oid($num, $self) or next;
				reindex_oid_m($self, $sync, $git, $oid, $num);
			}
		}
	}
	$git->cleanup if $git;
	$self->done;

	if (my $nr = $sync->{nr}) {
		my $pr = $sync->{-opt}->{-progress};
		$pr->('all.git '.sprintf($sync->{-regen_fmt}, $nr)) if $pr;
	}
	$self->{over}->rethread_done($opt);

	# reindex does not pick up new changes, so we rerun w/o it:
	if ($opt->{reindex}) {
		my %again = %$opt;
		$sync = undef;
		delete @again{qw(rethread reindex -skip_lock)};
		index_sync($self, \%again);
	}
}

1;
