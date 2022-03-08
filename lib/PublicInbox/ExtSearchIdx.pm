# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Detached/external index cross inbox search indexing support
# read-write counterpart to PublicInbox::ExtSearch
#
# It's based on the same ideas as public-inbox-v2-format(5) using
# over.sqlite3 for dedupe and sharded Xapian.  msgmap.sqlite3 is
# missing, so there is no Message-ID conflict resolution, meaning
# no NNTP support for now.
#
# v2 has a 1:1 mapping of index:inbox or msgmap for NNTP support.
# This is intended to be an M:N index:inbox mapping, but it'll likely
# be 1:N in common practice (M==1)

package PublicInbox::ExtSearchIdx;
use strict;
use v5.10.1;
use parent qw(PublicInbox::ExtSearch PublicInbox::Lock);
use Carp qw(croak carp);
use Scalar::Util qw(blessed);
use Sys::Hostname qw(hostname);
use POSIX qw(strftime);
use File::Glob qw(bsd_glob GLOB_NOSORT);
use PublicInbox::MultiGit;
use PublicInbox::Search;
use PublicInbox::SearchIdx qw(prepare_stack is_ancestor is_bad_blob);
use PublicInbox::OverIdx;
use PublicInbox::MiscIdx;
use PublicInbox::MID qw(mids);
use PublicInbox::V2Writable;
use PublicInbox::InboxWritable;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::Eml;
use PublicInbox::DS qw(now add_timer);
use DBI qw(:sql_types); # SQL_BLOB

sub new {
	my (undef, $dir, $opt) = @_;
	my $l = $opt->{indexlevel} // 'full';
	$l !~ $PublicInbox::SearchIdx::INDEXLEVELS and
		die "invalid indexlevel=$l\n";
	$l eq 'basic' and die "E: indexlevel=basic not yet supported\n";
	my $self = bless {
		xpfx => "$dir/ei".PublicInbox::Search::SCHEMA_VERSION,
		topdir => $dir,
		creat => $opt->{creat},
		ibx_map => {}, # (newsgroup//inboxdir) => $ibx
		ibx_active => [], # by config section order
		ibx_known => [], # by config section order
		indexlevel => $l,
		transact_bytes => 0,
		total_bytes => 0,
		current_info => '',
		parallel => 1,
		lock_path => "$dir/ei.lock",
	}, __PACKAGE__;
	$self->{shards} = $self->count_shards ||
		nproc_shards({ nproc => $opt->{jobs} });
	my $oidx = PublicInbox::OverIdx->new("$self->{xpfx}/over.sqlite3");
	$self->{-no_fsync} = $oidx->{-no_fsync} = 1 if !$opt->{fsync};
	$self->{-dangerous} = 1 if $opt->{dangerous};
	$self->{oidx} = $oidx;
	$self
}

sub attach_inbox {
	my ($self, $ibx, $types) = @_;
	$self->{ibx_map}->{$ibx->eidx_key} //= do {
		delete $self->{-ibx_ary_known}; # invalidate cache
		delete $self->{-ibx_ary_active}; # invalidate cache
		$types //= [ qw(active known) ];
		for my $t (@$types) {
			push @{$self->{"ibx_$t"}}, $ibx;
		}
		$ibx;
	}
}

sub _ibx_attach { # each_inbox callback
	my ($ibx, $self, $types) = @_;
	attach_inbox($self, $ibx, $types);
}

sub attach_config {
	my ($self, $cfg, $ibxs) = @_;
	$self->{cfg} = $cfg;
	my $types;
	if ($ibxs) {
		for my $ibx (@$ibxs) {
			$self->{ibx_map}->{$ibx->eidx_key} //= do {
				push @{$self->{ibx_active}}, $ibx;
				push @{$self->{ibx_known}}, $ibx;
				$ibx;
			}
		}
		# invalidate cache
		delete $self->{-ibx_ary_known};
		delete $self->{-ibx_ary_active};
		$types = [ 'known' ];
	}
	$types //= [ qw(known active) ];
	$cfg->each_inbox(\&_ibx_attach, $self, $types);
}

sub check_batch_limit ($) {
	my ($req) = @_;
	my $self = $req->{self};
	my $new_smsg = $req->{new_smsg};
	my $n = $self->{transact_bytes} += $new_smsg->{bytes};

	# set flag for PublicInbox::V2Writable::index_todo:
	${$req->{need_checkpoint}} = 1 if $n >= $self->{batch_bytes};
}

sub apply_boost ($$) {
	my ($req, $smsg) = @_;
	my $id2pos = $req->{id2pos}; # index in ibx_sorted
	my $xr3 = $req->{self}->{oidx}->get_xref3($smsg->{num}, 1);
	@$xr3 = sort {
		$id2pos->{$a->[0]} <=> $id2pos->{$b->[0]}
				||
		$a->[1] <=> $b->[1] # break ties with {xnum}
	} @$xr3;
	my $new_smsg = $req->{new_smsg};
	return if $xr3->[0]->[2] ne $new_smsg->oidbin; # loser

	# replace the old smsg with the more boosted one
	$new_smsg->{num} = $smsg->{num};
	$new_smsg->populate($req->{eml}, $req);
	$req->{self}->{oidx}->add_overview($req->{eml}, $new_smsg);
}

sub remove_doc ($$) {
	my ($self, $docid) = @_;
	$self->{oidx}->delete_by_num($docid);
	$self->{oidx}->eidxq_del($docid);
	$self->idx_shard($docid)->ipc_do('xdb_remove', $docid);
}

sub _unref_doc ($$$$$;$) {
	my ($sync, $docid, $ibx, $xnum, $oidbin, $eml) = @_;
	my $smsg;
	if (ref($docid)) {
		$smsg = $docid;
		$docid = $smsg->{num};
	}
	if (defined($oidbin) && defined($xnum) && blessed($ibx) && $ibx->over) {
		my $smsg = $ibx->over->get_art($xnum);
		if ($smsg && $smsg->oidbin eq $oidbin) {
			carp("BUG: (non-fatal) ".$ibx->eidx_key.
				" #$xnum $smsg->{blob} still valid");
			return;
		}
	}
	my $s = 'DELETE FROM xref3 WHERE oidbin = ?';
	$s .= ' AND ibx_id = ?' if defined($ibx);
	$s .= ' AND xnum = ?' if defined($xnum);
	my $del = $sync->{self}->{oidx}->dbh->prepare_cached($s);
	my $col = 0;
	$del->bind_param(++$col, $oidbin, SQL_BLOB);
	$del->bind_param(++$col, $ibx->{-ibx_id}) if $ibx;
	$del->bind_param(++$col, $xnum) if defined($xnum);
	$del->execute;
	my $xr3 = $sync->{self}->{oidx}->get_xref3($docid);
	if (scalar(@$xr3) == 0) { # all gone
		remove_doc($sync->{self}, $docid);
	} else { # enqueue for reindex of remaining messages
		if ($ibx) {
			my $ekey = $ibx->{-gc_eidx_key} // $ibx->eidx_key;
			my $idx = $sync->{self}->idx_shard($docid);
			$idx->ipc_do('remove_eidx_info', $docid, $ekey, $eml);
		} # else: we can't remove_eidx_info in reindex-only path

		# replace invalidated blob ASAP with something which should be
		# readable since we may commit the transaction on checkpoint.
		# eidxq processing will re-apply boost
		$smsg //= $sync->{self}->{oidx}->get_art($docid);
		my $hex = unpack('H*', $oidbin);
		if ($smsg && $smsg->{blob} eq $hex) {
			$xr3->[0] =~ /:([a-f0-9]{40,}+)\z/ or
				die "BUG: xref $xr3->[0] has no OID";
			$sync->{self}->{oidx}->update_blob($smsg, $1);
		}
		# yes, add, we'll need to re-apply boost
		$sync->{self}->{oidx}->eidxq_add($docid);
	}
	@$xr3
}

sub do_xpost ($$) {
	my ($req, $smsg) = @_;
	my $self = $req->{self};
	my $docid = $smsg->{num};
	my $oid = $req->{oid};
	my $xibx = $req->{ibx};
	my $eml = $req->{eml};
	if (my $new_smsg = $req->{new_smsg}) { # 'm' on cross-posted message
		my $eidx_key = $xibx->eidx_key;
		my $xnum = $req->{xnum};
		$self->{oidx}->add_xref3($docid, $xnum, $oid, $eidx_key);
		my $idx = $self->idx_shard($docid);
		$idx->ipc_do('add_eidx_info', $docid, $eidx_key, $eml);
		apply_boost($req, $smsg) if $req->{boost_in_use};
	} else { # 'd' no {xnum}
		$self->git->async_wait_all;
		$oid = pack('H*', $oid);
		_unref_doc($req, $docid, $xibx, undef, $oid, $eml);
	}
}

# called by V2Writable::sync_prepare
sub artnum_max { $_[0]->{oidx}->eidx_max }

sub index_unseen ($) {
	my ($req) = @_;
	my $new_smsg = $req->{new_smsg} or die 'BUG: {new_smsg} unset';
	my $eml = delete $req->{eml};
	$new_smsg->populate($eml, $req);
	my $self = $req->{self};
	my $docid = $self->{oidx}->adj_counter('eidx_docid', '+');
	$new_smsg->{num} = $docid;
	my $idx = $self->idx_shard($docid);
	$self->{oidx}->add_overview($eml, $new_smsg);
	my $oid = $new_smsg->{blob};
	my $ibx = delete $req->{ibx} or die 'BUG: {ibx} unset';
	$self->{oidx}->add_xref3($docid, $req->{xnum}, $oid, $ibx->eidx_key);
	$idx->index_eml($eml, $new_smsg, $ibx->eidx_key);
	check_batch_limit($req);
}

sub do_finalize ($) {
	my ($req) = @_;
	if (my $indexed = $req->{indexed}) { # duplicated messages
		do_xpost($req, $_) for @$indexed;
	} elsif (exists $req->{new_smsg}) { # totally unseen messsage
		index_unseen($req);
	} else {
		# `d' message was already unindexed in the v1/v2 inboxes,
		# so it's too noisy to warn, here.
	}
	# cur_cmt may be undef for unindex_oid, set by V2Writable::index_todo
	if (defined(my $cur_cmt = $req->{cur_cmt})) {
		${$req->{latest_cmt}} = $cur_cmt;
	}
}

sub do_step ($) { # main iterator for adding messages to the index
	my ($req) = @_;
	my $self = $req->{self} // die 'BUG: {self} missing';
	while (1) {
		if (my $next_arg = $req->{next_arg}) {
			if (my $smsg = $self->{oidx}->next_by_mid(@$next_arg)) {
				$req->{cur_smsg} = $smsg;
				$self->git->cat_async($smsg->{blob},
							\&ck_existing, $req);
				return; # ck_existing calls do_step
			}
			delete $req->{next_arg};
		}
		die "BUG: {cur_smsg} still set" if $req->{cur_smsg};
		my $mid = shift(@{$req->{mids}}) // last;
		my ($id, $prev);
		$req->{next_arg} = [ $mid, \$id, \$prev ];
		# loop again
	}
	do_finalize($req);
}

sub _blob_missing ($$) { # called when a known $smsg->{blob} is gone
	my ($req, $smsg) = @_;
	# xnum and ibx are unknown, we only call this when an entry from
	# /ei*/over.sqlite3 is bad, not on entries from xap*/over.sqlite3
	$req->{self}->git->async_wait_all;
	_unref_doc($req, $smsg, undef, undef, $smsg->oidbin);
}

sub ck_existing { # git->cat_async callback
	my ($bref, $oid, $type, $size, $req) = @_;
	my $smsg = delete $req->{cur_smsg} or die 'BUG: {cur_smsg} missing';
	if ($type eq 'missing') {
		_blob_missing($req, $smsg);
	} elsif (!is_bad_blob($oid, $type, $size, $smsg->{blob})) {
		my $self = $req->{self} // die 'BUG: {self} missing';
		local $self->{current_info} = "$self->{current_info} $oid";
		my $cur = PublicInbox::Eml->new($bref);
		if (content_hash($cur) eq $req->{chash}) {
			push @{$req->{indexed}}, $smsg; # for do_xpost
		} # else { index_unseen later }
	}
	do_step($req);
}

# is the messages visible in the inbox currently being indexed?
# return the number if so
sub cur_ibx_xnum ($$;$) {
	my ($req, $bref, $mismatch) = @_;
	my $ibx = $req->{ibx} or die 'BUG: current {ibx} missing';

	$req->{eml} = PublicInbox::Eml->new($bref);
	$req->{chash} = content_hash($req->{eml});
	$req->{mids} = mids($req->{eml});
	for my $mid (@{$req->{mids}}) {
		my ($id, $prev);
		while (my $x = $ibx->over->next_by_mid($mid, \$id, \$prev)) {
			return $x->{num} if $x->{blob} eq $req->{oid};
			push @$mismatch, $x if $mismatch;
		}
	}
	undef;
}

sub index_oid { # git->cat_async callback for 'm'
	my ($bref, $oid, $type, $size, $req) = @_;
	my $self = $req->{self};
	local $self->{current_info} = "$self->{current_info} $oid";
	return if is_bad_blob($oid, $type, $size, $req->{oid});
	my $new_smsg = $req->{new_smsg} = bless {
		blob => $oid,
	}, 'PublicInbox::Smsg';
	$new_smsg->set_bytes($$bref, $size);
	++${$req->{nr}};
	my $mismatch = [];
	$req->{xnum} = cur_ibx_xnum($req, $bref, $mismatch) // do {
		warn "# deleted\n";
		warn "# mismatch $_->{blob}\n" for @$mismatch;
		${$req->{latest_cmt}} = $req->{cur_cmt} //
			die "BUG: {cur_cmt} unset ($oid)\n";
		return;
	};
	do_step($req);
}

sub unindex_oid { # git->cat_async callback for 'd'
	my ($bref, $oid, $type, $size, $req) = @_;
	my $self = $req->{self};
	local $self->{current_info} = "$self->{current_info} $oid";
	return if is_bad_blob($oid, $type, $size, $req->{oid});
	return if defined(cur_ibx_xnum($req, $bref)); # was re-added
	do_step($req);
}

# overrides V2Writable::last_commits, called by sync_ranges via sync_prepare
sub last_commits {
	my ($self, $sync) = @_;
	my $heads = [];
	my $ekey = $sync->{ibx}->eidx_key;
	my $uv = $sync->{ibx}->uidvalidity;
	for my $i (0..$sync->{epoch_max}) {
		$heads->[$i] = $self->{oidx}->eidx_meta("lc-v2:$ekey//$uv;$i");
	}
	$heads;
}

sub _ibx_index_reject ($) {
	my ($ibx) = @_;
	$ibx->mm // return 'unindexed, no msgmap.sqlite3';
	$ibx->uidvalidity // return 'no UIDVALIDITY';
	$ibx->over // return 'unindexed, no over.sqlite3';
	undef;
}

sub _sync_inbox ($$$) {
	my ($self, $sync, $ibx) = @_;
	my $ekey = $ibx->eidx_key;
	if (defined(my $err = _ibx_index_reject($ibx))) {
		return "W: skipping $ekey ($err)";
	}
	$sync->{ibx} = $ibx;
	$sync->{nr} = \(my $nr = 0);
	my $v = $ibx->version;
	if ($v == 2) {
		$sync->{epoch_max} = $ibx->max_git_epoch // return;
		sync_prepare($self, $sync); # or return # TODO: once MiscIdx is stable
	} elsif ($v == 1) {
		my $uv = $ibx->uidvalidity;
		my $lc = $self->{oidx}->eidx_meta("lc-v1:$ekey//$uv");
		my $head = $ibx->mm->last_commit //
			return "E: $ibx->{inboxdir} is not indexed";
		my $stk = prepare_stack($sync, $lc ? "$lc..$head" : $head);
		my $unit = { stack => $stk, git => $ibx->git };
		push @{$sync->{todo}}, $unit;
	} else {
		return "E: $ekey unsupported inbox version (v$v)";
	}
	for my $unit (@{delete($sync->{todo}) // []}) {
		last if $sync->{quit};
		index_todo($self, $sync, $unit);
	}
	$self->{midx}->index_ibx($ibx) unless $sync->{quit};
	$ibx->git->cleanup; # done with this inbox, now
	undef;
}

sub eidx_gc_scan_inboxes ($$) {
	my ($self, $sync) = @_;
	my ($x3_doc, $ibx_ck);
restart:
	$x3_doc = $self->{oidx}->dbh->prepare(<<EOM);
SELECT docid,xnum,oidbin FROM xref3 WHERE ibx_id = ?
EOM
	$ibx_ck = $self->{oidx}->dbh->prepare(<<EOM);
SELECT ibx_id,eidx_key FROM inboxes
EOM
	$ibx_ck->execute;
	while (my ($ibx_id, $eidx_key) = $ibx_ck->fetchrow_array) {
		next if $self->{ibx_map}->{$eidx_key};
		$self->{midx}->remove_eidx_key($eidx_key);
		warn "I: deleting messages for $eidx_key...\n";
		$x3_doc->execute($ibx_id);
		my $ibx = { -ibx_id => $ibx_id, -gc_eidx_key => $eidx_key };
		while (my ($docid, $xnum, $oid) = $x3_doc->fetchrow_array) {
			my $r = _unref_doc($sync, $docid, $ibx, $xnum, $oid);
			$oid = unpack('H*', $oid);
			$r = $r ? 'unref' : 'remove';
			warn "I: $r #$docid $eidx_key $oid\n";
			if (checkpoint_due($sync)) {
				$x3_doc = $ibx_ck = undef;
				reindex_checkpoint($self, $sync);
				goto restart;
			}
		}
		$self->{oidx}->dbh->do(<<'', undef, $ibx_id);
DELETE FROM inboxes WHERE ibx_id = ?

		# drop last_commit info
		my $pat = $eidx_key;
		$pat =~ s/([_%\\])/\\$1/g;
		$self->{oidx}->dbh->do('PRAGMA case_sensitive_like = ON');
		my $lc_i = $self->{oidx}->dbh->prepare(<<'');
SELECT key FROM eidx_meta WHERE key LIKE ? ESCAPE ?

		$lc_i->execute("lc-%:$pat//%", '\\');
		while (my ($key) = $lc_i->fetchrow_array) {
			next if $key !~ m!\Alc-v[1-9]+:\Q$eidx_key\E//!;
			warn "I: removing $key\n";
			$self->{oidx}->dbh->do(<<'', undef, $key);
DELETE FROM eidx_meta WHERE key = ?

		}
		warn "I: $eidx_key removed\n";
	}
}

sub eidx_gc_scan_shards ($$) { # TODO: use for lei/store
	my ($self, $sync) = @_;
	my $nr = $self->{oidx}->dbh->do(<<'');
DELETE FROM xref3 WHERE docid NOT IN (SELECT num FROM over)

	warn "I: eliminated $nr stale xref3 entries\n" if $nr != 0;
	reindex_checkpoint($self, $sync) if checkpoint_due($sync);

	# fixup from old bugs:
	$nr = $self->{oidx}->dbh->do(<<'');
DELETE FROM over WHERE num > 0 AND num NOT IN (SELECT docid FROM xref3)

	warn "I: eliminated $nr stale over entries\n" if $nr != 0;
	reindex_checkpoint($self, $sync) if checkpoint_due($sync);

	$nr = $self->{oidx}->dbh->do(<<'');
DELETE FROM eidxq WHERE docid NOT IN (SELECT num FROM over)

	warn "I: eliminated $nr stale reindex queue entries\n" if $nr != 0;
	reindex_checkpoint($self, $sync) if checkpoint_due($sync);

	my ($cur) = $self->{oidx}->dbh->selectrow_array(<<EOM);
SELECT MIN(num) FROM over WHERE num > 0
EOM
	$cur // return; # empty
	my ($r, $n, %active_shards);
	$nr = 0;
	while (1) {
		$r = $self->{oidx}->dbh->selectcol_arrayref(<<"", undef, $cur);
SELECT num FROM over WHERE num >= ? ORDER BY num ASC LIMIT 10000

		last unless scalar(@$r);
		while (defined($n = shift @$r)) {
			for my $i ($cur..($n - 1)) {
				my $idx = idx_shard($self, $i);
				$idx->ipc_do('xdb_remove_quiet', $i);
				$active_shards{$idx} = $idx;
			}
			$cur = $n + 1;
		}
		if (checkpoint_due($sync)) {
			for my $idx (values %active_shards) {
				$nr += $idx->ipc_do('nr_quiet_rm')
			}
			%active_shards = ();
			reindex_checkpoint($self, $sync);
		}
	}
	warn "I: eliminated $nr stale Xapian documents\n" if $nr != 0;
}

sub eidx_gc {
	my ($self, $opt) = @_;
	$self->{cfg} or die "E: GC requires ->attach_config\n";
	$opt->{-idx_gc} = 1;
	my $sync = {
		need_checkpoint => \(my $need_checkpoint = 0),
		check_intvl => 10,
		next_check => now() + 10,
		checkpoint_unlocks => 1,
		-opt => $opt,
		self => $self,
	};
	$self->idx_init($opt); # acquire lock via V2Writable::_idx_init
	eidx_gc_scan_inboxes($self, $sync);
	eidx_gc_scan_shards($self, $sync);
	done($self);
}

sub _ibx_for ($$$) {
	my ($self, $sync, $smsg) = @_;
	my $ibx_id = delete($smsg->{ibx_id}) // die '{ibx_id} unset';
	my $pos = $sync->{id2pos}->{$ibx_id} // die "$ibx_id no pos";
	$self->{-ibx_ary_known}->[$pos] //
		die "BUG: ibx for $smsg->{blob} not mapped"
}

sub _fd_constrained ($) {
	my ($self) = @_;
	$self->{-fd_constrained} //= do {
		my $soft;
		if (eval { require BSD::Resource; 1 }) {
			my $NOFILE = BSD::Resource::RLIMIT_NOFILE();
			($soft, undef) = BSD::Resource::getrlimit($NOFILE);
		} else {
			chomp($soft = `sh -c 'ulimit -n'`);
		}
		if (defined($soft)) {
			# $want is an estimate
			my $want = scalar(@{$self->{ibx_active}}) + 64;
			my $ret = $want > $soft;
			if ($ret) {
				warn <<EOF;
RLIMIT_NOFILE=$soft insufficient (want: $want), will close DB handles early
EOF
			}
			$ret;
		} else {
			warn "Unable to determine RLIMIT_NOFILE: $@\n";
			1;
		}
	};
}

sub _reindex_finalize ($$$) {
	my ($req, $smsg, $eml) = @_;
	my $sync = $req->{sync};
	my $self = $sync->{self};
	my $by_chash = delete $req->{by_chash} or die 'BUG: no {by_chash}';
	my $nr = scalar(keys(%$by_chash)) or die 'BUG: no content hashes';
	my $orig_smsg = $req->{orig_smsg} // die 'BUG: no {orig_smsg}';
	my $docid = $smsg->{num} = $orig_smsg->{num};
	$self->{oidx}->add_overview($eml, $smsg); # may rethread
	check_batch_limit({ %$sync, new_smsg => $smsg });
	my $chash0 = $smsg->{chash} // die "BUG: $smsg->{blob} no {chash}";
	my $stable = delete($by_chash->{$chash0}) //
				die "BUG: $smsg->{blob} chash missing";
	my $idx = $self->idx_shard($docid);
	my $top_smsg = pop @$stable;
	$top_smsg == $smsg or die 'BUG: top_smsg != smsg';
	my $ibx = _ibx_for($self, $sync, $smsg);
	$idx->index_eml($eml, $smsg, $ibx->eidx_key);
	for my $x (reverse @$stable) {
		$ibx = _ibx_for($self, $sync, $x);
		my $hdr = delete $x->{hdr} // die 'BUG: no {hdr}';
		$idx->ipc_do('add_eidx_info', $docid, $ibx->eidx_key, $hdr);
	}
	return if $nr == 1; # likely, all good

	$self->git->async_wait_all;
	warn "W: #$docid split into $nr due to deduplication change\n";
	my @todo;
	for my $ary (values %$by_chash) {
		for my $x (reverse @$ary) {
			warn "removing #$docid xref3 $x->{blob}\n";
			my $bin = $x->oidbin;
			my $n = _unref_doc($sync, $docid, undef, undef, $bin);
			die "BUG: $x->{blob} invalidated #$docid" if $n == 0;
		}
		my $x = pop(@$ary) // die "BUG: #$docid {by_chash} empty";
		$x->{num} = delete($x->{xnum}) // die '{xnum} unset';
		$ibx = _ibx_for($self, $sync, $x);
		if (my $over = $ibx->over) {
			my $e = $over->get_art($x->{num});
			$e->{blob} eq $x->{blob} or die <<EOF;
$x->{blob} != $e->{blob} (${\$ibx->eidx_key}:$e->{num});
EOF
			push @todo, $ibx, $e;
			$over->dbh_close if _fd_constrained($self);
		} else {
			die "$ibx->{inboxdir}: over.sqlite3 unusable: $!\n";
		}
	}
	undef $by_chash;
	while (my ($ibx, $e) = splice(@todo, 0, 2)) {
		reindex_unseen($self, $sync, $ibx, $e);
	}
}

sub _reindex_oid { # git->cat_async callback
	my ($bref, $oid, $type, $size, $req) = @_;
	my $sync = $req->{sync};
	my $self = $sync->{self};
	my $orig_smsg = $req->{orig_smsg} // die 'BUG: no {orig_smsg}';
	my $expect_oid = $req->{xr3r}->[$req->{ix}]->[2];
	my $docid = $orig_smsg->{num};
	if (is_bad_blob($oid, $type, $size, $expect_oid)) {
		my $oidbin = pack('H*', $expect_oid);
		my $remain = _unref_doc($sync, $docid, undef, undef, $oidbin);
		if ($remain == 0) {
			warn "W: #$docid ($oid) gone or corrupt\n";
		} elsif (my $next_oid = $req->{xr3r}->[++$req->{ix}]->[2]) {
			$self->git->cat_async($next_oid, \&_reindex_oid, $req);
		} else {
			warn "BUG: #$docid ($oid) gone (UNEXPECTED)\n";
		}
		return;
	}
	my $ci = $self->{current_info};
	local $self->{current_info} = "$ci #$docid $oid";
	my $re_smsg = bless { blob => $oid }, 'PublicInbox::Smsg';
	$re_smsg->set_bytes($$bref, $size);
	my $eml = PublicInbox::Eml->new($bref);
	$re_smsg->populate($eml, { autime => $orig_smsg->{ds},
				cotime => $orig_smsg->{ts} });
	my $chash = content_hash($eml);
	$re_smsg->{chash} = $chash;
	$re_smsg->{xnum} = $req->{xr3r}->[$req->{ix}]->[1];
	$re_smsg->{ibx_id} = $req->{xr3r}->[$req->{ix}]->[0];
	$re_smsg->{hdr} = $eml->header_obj;
	push @{$req->{by_chash}->{$chash}}, $re_smsg;
	if (my $next_oid = $req->{xr3r}->[++$req->{ix}]->[2]) {
		$self->git->cat_async($next_oid, \&_reindex_oid, $req);
	} else { # last $re_smsg is the highest priority xref3
		local $self->{current_info} = "$ci #$docid";
		_reindex_finalize($req, $re_smsg, $eml);
	}
}

sub _reindex_smsg ($$$) {
	my ($self, $sync, $smsg) = @_;
	my $docid = $smsg->{num};
	my $xr3 = $self->{oidx}->get_xref3($docid, 1);
	if (scalar(@$xr3) == 0) { # _reindex_check_stale should've covered this
		warn <<"";
BUG? #$docid $smsg->{blob} is not referenced by inboxes during reindex

		remove_doc($self, $docid);
		return;
	}

	# we sort {xr3r} in the reverse order of ibx_sorted so we can
	# hit the common case in _reindex_finalize without rereading
	# from git (or holding multiple messages in memory).
	my $id2pos = $sync->{id2pos}; # index in ibx_sorted
	@$xr3 = sort {
		$id2pos->{$b->[0]} <=> $id2pos->{$a->[0]}
				||
		$b->[1] <=> $a->[1] # break ties with {xnum}
	} @$xr3;
	@$xr3 = map { [ $_->[0], $_->[1], unpack('H*', $_->[2]) ] } @$xr3;
	my $req = { orig_smsg => $smsg, sync => $sync, xr3r => $xr3, ix => 0 };
	$self->git->cat_async($xr3->[$req->{ix}]->[2], \&_reindex_oid, $req);
}

sub checkpoint_due ($) {
	my ($sync) = @_;
	${$sync->{need_checkpoint}} || (now() > $sync->{next_check});
}

sub host_ident () {
	# I've copied FS images and only changed the hostname before,
	# so prepend hostname.  Use `state' since these a BOFH can change
	# these while this process is running and we always want to be
	# able to release locks taken by this process.
	state $retval = hostname . '-' . do {
		my $m; # machine-id(5) is systemd
		if (open(my $fh, '<', '/etc/machine-id')) { $m = <$fh> }
		# (g)hostid(1) is in GNU coreutils, kern.hostid is most BSDs
		chomp($m ||= `{ sysctl -n kern.hostid ||
				hostid || ghostid; } 2>/dev/null`
			|| "no-machine-id-or-hostid-on-$^O");
		$m;
	};
}

sub eidxq_release {
	my ($self) = @_;
	my $expect = delete($self->{-eidxq_locked}) or return;
	my ($owner_pid, undef) = split(/-/, $expect);
	return if $owner_pid != $$; # shards may fork
	my $oidx = $self->{oidx};
	$oidx->begin_lazy;
	my $cur = $oidx->eidx_meta('eidxq_lock') // '';
	if ($cur eq $expect) {
		$oidx->eidx_meta('eidxq_lock', '');
		return 1;
	} elsif ($cur ne '') {
		warn "E: eidxq_lock($expect) stolen by $cur\n";
	} else {
		warn "E: eidxq_lock($expect) released by another process\n";
	}
	undef;
}

sub DESTROY {
	my ($self) = @_;
	eidxq_release($self) and $self->{oidx}->commit_lazy;
}

sub _eidxq_take ($) {
	my ($self) = @_;
	my $val = "$$-${\time}-$>-".host_ident;
	$self->{oidx}->eidx_meta('eidxq_lock', $val);
	$self->{-eidxq_locked} = $val;
}

sub eidxq_lock_acquire ($) {
	my ($self) = @_;
	my $oidx = $self->{oidx};
	$oidx->begin_lazy;
	my $cur = $oidx->eidx_meta('eidxq_lock') || return _eidxq_take($self);
	if (my $locked = $self->{-eidxq_locked}) { # be lazy
		return $locked if $locked eq $cur;
	}
	my ($pid, $time, $euid, $ident) = split(/-/, $cur, 4);
	my $t = strftime('%Y-%m-%d %k:%M %z', localtime($time));
	local $self->{current_info} = 'eidxq';
	if ($euid == $> && $ident eq host_ident) {
		if (kill(0, $pid)) {
			warn <<EOM; return;
I: PID:$pid (re)indexing since $t, it will continue our work
EOM
		}
		if ($!{ESRCH}) {
			warn "I: eidxq_lock is stale ($cur), clobbering\n";
			return _eidxq_take($self);
		}
		warn "E: kill(0, $pid) failed: $!\n"; # fall-through:
	}
	my $fn = $oidx->dbh->sqlite_db_filename;
	warn <<EOF;
W: PID:$pid, UID:$euid on $ident is indexing Xapian since $t
W: If this is unexpected, delete `eidxq_lock' from the `eidx_meta' table:
W:	sqlite3 $fn 'DELETE FROM eidx_meta WHERE key = "eidxq_lock"'
EOF
	undef;
}

sub ibx_sorted ($$) {
	my ($self, $type) = @_;
	$self->{"-ibx_ary_$type"} //= do {
		# highest boost first, stable for config-ordering tiebreaker
		use sort 'stable';
		[ sort {
			($b->{boost} // 0) <=> ($a->{boost} // 0)
		  } @{$self->{'ibx_'.$type} // die "BUG: $type unknown"} ];
	}
}

sub prep_id2pos ($) {
	my ($self) = @_;
	my %id2pos;
	my $pos = 0;
	$id2pos{$_->{-ibx_id}} = $pos++ for (@{ibx_sorted($self, 'known')});
	\%id2pos;
}

sub eidxq_process ($$) { # for reindexing
	my ($self, $sync) = @_;
	local $self->{current_info} = 'eidxq process';
	return unless ($self->{cfg} && eidxq_lock_acquire($self));
	my $dbh = $self->{oidx}->dbh;
	my $tot = $dbh->selectrow_array('SELECT COUNT(*) FROM eidxq') or return;
	${$sync->{nr}} = 0;
	local $sync->{-regen_fmt} = "%u/$tot\n";
	my $pr = $sync->{-opt}->{-progress};
	if ($pr) {
		my $min = $dbh->selectrow_array('SELECT MIN(docid) FROM eidxq');
		my $max = $dbh->selectrow_array('SELECT MAX(docid) FROM eidxq');
		$pr->("Xapian indexing $min..$max (total=$tot)\n");
	}
	$sync->{id2pos} //= prep_id2pos($self);
	my ($del, $iter);
restart:
	$del = $dbh->prepare('DELETE FROM eidxq WHERE docid = ?');
	$iter = $dbh->prepare('SELECT docid FROM eidxq ORDER BY docid ASC');
	$iter->execute;
	while (defined(my $docid = $iter->fetchrow_array)) {
		last if $sync->{quit};
		if (my $smsg = $self->{oidx}->get_art($docid)) {
			_reindex_smsg($self, $sync, $smsg);
		} else {
			warn "E: #$docid does not exist in over\n";
		}
		$del->execute($docid);
		++${$sync->{nr}};

		if (checkpoint_due($sync)) {
			$dbh = $del = $iter = undef;
			reindex_checkpoint($self, $sync); # release lock
			$dbh = $self->{oidx}->dbh;
			goto restart;
		}
	}
	$self->git->async_wait_all;
	$pr->("reindexed ${$sync->{nr}}/$tot\n") if $pr;
}

sub _reindex_unseen { # git->cat_async callback
	my ($bref, $oid, $type, $size, $req) = @_;
	return if is_bad_blob($oid, $type, $size, $req->{oid});
	my $self = $req->{self} // die 'BUG: {self} unset';
	local $self->{current_info} = "$self->{current_info} $oid";
	my $new_smsg = bless { blob => $oid, }, 'PublicInbox::Smsg';
	$new_smsg->set_bytes($$bref, $size);
	my $eml = $req->{eml} = PublicInbox::Eml->new($bref);
	$req->{new_smsg} = $new_smsg;
	$req->{chash} = content_hash($eml);
	$req->{mids} = mids($eml); # do_step iterates through this
	do_step($req); # enter the normal indexing flow
}

# --reindex may catch totally unseen messages, this handles them
sub reindex_unseen ($$$$) {
	my ($self, $sync, $ibx, $xsmsg) = @_;
	my $req = {
		%$sync, # has {self}
		autime => $xsmsg->{ds},
		cotime => $xsmsg->{ts},
		oid => $xsmsg->{blob},
		ibx => $ibx,
		xnum => $xsmsg->{num},
		# {mids} and {chash} will be filled in at _reindex_unseen
	};
	warn "I: reindex_unseen ${\$ibx->eidx_key}:$req->{xnum}:$req->{oid}\n";
	$self->git->cat_async($xsmsg->{blob}, \&_reindex_unseen, $req);
}

sub _unref_stale_range ($$$) {
	my ($sync, $ibx, $lt_or_gt) = @_;
	my $r;
	my $lim = 10000;
	do {
		$r = $sync->{self}->{oidx}->dbh->selectall_arrayref(
			<<EOS, undef, $ibx->{-ibx_id});
SELECT docid,xnum,oidbin FROM xref3
WHERE ibx_id = ? AND $lt_or_gt LIMIT $lim
EOS
		return if $sync->{quit};
		for (@$r) { # hopefully rare, not worth optimizing:
			my ($docid, $xnum, $oidbin) = @$_;
			my $hex = unpack('H*', $oidbin);
			warn("# $xnum:$hex (#$docid): stale\n");
			_unref_doc($sync, $docid, $ibx, $xnum, $oidbin);
		}
	} while (scalar(@$r) == $lim);
	1;
}

sub _reindex_check_ibx ($$$) {
	my ($self, $sync, $ibx) = @_;
	my $ibx_id = $ibx->{-ibx_id};
	my $slice = 10000;
	my $opt = { limit => $slice };
	my ($beg, $end) = (1, $slice);
	my $ekey = $ibx->eidx_key;
	my ($max, $max0);
	do {
		$max0 = $ibx->mm->num_highwater;
		sync_inbox($self, $sync, $ibx) and return; # warned
		$max = $ibx->mm->num_highwater;
		return if $sync->{quit};
	} while ($max > $max0 &&
		warn("# $ekey moved $max0..$max, resyncing..\n"));
	$end = $max if $end > $max;

	# first, check if we missed any messages in target $ibx
	my $msgs;
	my $pr = $sync->{-opt}->{-progress};
	local $sync->{-regen_fmt} = "$ekey checking %u/$max\n";
	${$sync->{nr}} = 0;
	my $fast = $sync->{-opt}->{fast};
	my $usr; # _unref_stale_range (< $lo) called
	my ($lo, $hi);
	while (scalar(@{$msgs = $ibx->over->query_xover($beg, $end, $opt)})) {
		${$sync->{nr}} = $beg;
		$beg = $msgs->[-1]->{num} + 1;
		$end = $beg + $slice;
		$end = $max if $end > $max;
		if (checkpoint_due($sync)) {
			reindex_checkpoint($self, $sync); # release lock
		}
		($lo, $hi) = ($msgs->[0]->{num}, $msgs->[-1]->{num});
		$usr //= _unref_stale_range($sync, $ibx, "xnum < $lo");
		my $x3a = $self->{oidx}->dbh->selectall_arrayref(
			<<"", undef, $ibx_id, $lo, $hi);
SELECT xnum,oidbin,docid FROM xref3 WHERE
ibx_id = ? AND xnum >= ? AND xnum <= ?

		my %x3m;
		for (@$x3a) {
			my $k = pack('J', $_->[0]) . $_->[1];
			push @{$x3m{$k}}, $_->[2];
		}
		undef $x3a;
		for my $xsmsg (@$msgs) {
			my $k = pack('JH*', $xsmsg->{num}, $xsmsg->{blob});
			my $docids = delete($x3m{$k});
			if (!defined($docids)) {
				reindex_unseen($self, $sync, $ibx, $xsmsg);
			} elsif (!$fast) {
				for my $num (@$docids) {
					$self->{oidx}->eidxq_add($num);
				}
			}
			return if $sync->{quit};
		}
		next unless scalar keys %x3m;
		$self->git->async_wait_all; # wait for reindex_unseen

		# eliminate stale/mismatched entries
		my %mismatch = map { $_->{num} => $_->{blob} } @$msgs;
		while (my ($k, $docids) = each %x3m) {
			my ($xnum, $hex) = unpack('JH*', $k);
			my $bin = pack('H*', $hex);
			my $exp = $mismatch{$xnum};
			if (defined $exp) {
				my $smsg = $ibx->over->get_art($xnum) // next;
				# $xnum may be expired by another process
				if ($smsg->{blob} eq $hex) {
					warn <<"";
BUG: (non-fatal) $ekey #$xnum $smsg->{blob} still matches (old exp: $exp)

					next;
				} # else: continue to unref
			}
			my $m = defined($exp) ? "mismatch (!= $exp)" : 'stale';
			warn("# $xnum:$hex (#@$docids): $m\n");
			for my $i (@$docids) {
				_unref_doc($sync, $i, $ibx, $xnum, $bin);
			}
			return if $sync->{quit};
		}
	}
	defined($hi) and ($hi < $max) and
		_unref_stale_range($sync, $ibx, "xnum > $hi AND xnum <= $max");
}

sub _reindex_inbox ($$$) {
	my ($self, $sync, $ibx) = @_;
	my $ekey = $ibx->eidx_key;
	local $self->{current_info} = $ekey;
	if (defined(my $err = _ibx_index_reject($ibx))) {
		warn "W: cannot reindex $ekey ($err)\n";
	} else {
		_reindex_check_ibx($self, $sync, $ibx);
	}
	delete @$ibx{qw(over mm search git)}; # won't need these for a bit
}

sub eidx_reindex {
	my ($self, $sync) = @_;
	return unless $self->{cfg};

	# acquire eidxq_lock early because full reindex takes forever
	# and incremental -extindex processes can run during our checkpoints
	if (!eidxq_lock_acquire($self)) {
		warn "E: aborting --reindex\n";
		return;
	}
	for my $ibx (@{ibx_sorted($self, 'active')}) {
		_reindex_inbox($self, $sync, $ibx);
		last if $sync->{quit};
	}
	$self->git->async_wait_all; # ensure eidxq gets filled completely
	eidxq_process($self, $sync) unless $sync->{quit};
}

sub sync_inbox {
	my ($self, $sync, $ibx) = @_;
	my $err = _sync_inbox($self, $sync, $ibx);
	delete @$ibx{qw(mm over)};
	warn $err, "\n" if defined($err);
	$err;
}

sub dd_smsg { # git->cat_async callback
	my ($bref, $oid, $type, $size, $dd) = @_;
	my $smsg = $dd->{smsg} // die 'BUG: dd->{smsg} missing';
	my $self = $dd->{self} // die 'BUG: {self} missing';
	my $per_mid = $dd->{per_mid} // die 'BUG: {per_mid} missing';
	if ($type eq 'missing') {
		_blob_missing($dd, $smsg);
	} elsif (!is_bad_blob($oid, $type, $size, $smsg->{blob})) {
		local $self->{current_info} = "$self->{current_info} $oid";
		my $chash = content_hash(PublicInbox::Eml->new($bref));
		push(@{$per_mid->{dd_chash}->{$chash}}, $smsg);
	}
	return if $per_mid->{last_smsg} != $smsg;
	while (my ($chash, $ary) = each %{$per_mid->{dd_chash}}) {
		my $keep = shift @$ary;
		next if !scalar(@$ary);
		$per_mid->{sync}->{dedupe_cull} += scalar(@$ary);
		print STDERR
			"# <$keep->{mid}> keeping #$keep->{num}, dropping ",
			join(', ', map { "#$_->{num}" } @$ary),"\n";
		next if $per_mid->{sync}->{-opt}->{'dry-run'};
		my $oidx = $self->{oidx};
		for my $smsg (@$ary) {
			my $gone = $smsg->{num};
			$oidx->merge_xref3($keep->{num}, $gone, $smsg->oidbin);
			remove_doc($self, $gone);
		}
	}
}

sub eidx_dedupe ($$$) {
	my ($self, $sync, $msgids) = @_;
	$sync->{dedupe_cull} = 0;
	my $candidates = 0;
	my $nr_mid = 0;
	return unless eidxq_lock_acquire($self);
	my ($iter, $cur_mid);
	my $min_id = 0;
	my $idx = 0;
	my ($max_id) = $self->{oidx}->dbh->selectrow_array(<<EOS);
SELECT MAX(id) FROM msgid
EOS
	local $sync->{-regen_fmt} = "dedupe %u/$max_id\n";

	# note: we could write this query more intelligently,
	# but that causes lock contention with read-only processes
dedupe_restart:
	$cur_mid = $msgids->[$idx];
	if ($cur_mid eq '') { # all Message-IDs
		$iter = $self->{oidx}->dbh->prepare(<<EOS);
SELECT mid,id FROM msgid WHERE id > ? ORDER BY id ASC
EOS
		$iter->execute($min_id);
	} else {
		$iter = $self->{oidx}->dbh->prepare(<<EOS);
SELECT mid,id FROM msgid WHERE mid = ? AND id > ? ORDER BY id ASC
EOS
		$iter->execute($cur_mid, $min_id);
	}
	while (my ($mid, $id) = $iter->fetchrow_array) {
		last if $sync->{quit};
		$self->{current_info} = "dedupe $mid";
		${$sync->{nr}} = $min_id = $id;
		my ($prv, @smsg);
		while (my $x = $self->{oidx}->next_by_mid($mid, \$id, \$prv)) {
			push @smsg, $x;
		}
		next if scalar(@smsg) < 2;
		my $per_mid = {
			dd_chash => {}, # chash => [ary of smsgs]
			last_smsg => $smsg[-1],
			sync => $sync
		};
		$nr_mid++;
		$candidates += scalar(@smsg) - 1;
		for my $smsg (@smsg) {
			my $dd = {
				per_mid => $per_mid,
				smsg => $smsg,
				self => $self,
			};
			$self->git->cat_async($smsg->{blob}, \&dd_smsg, $dd);
		}
		# need to wait on every single one @smsg contents can get
		# invalidated inside dd_smsg for messages with multiple
		# Message-IDs.
		$self->git->async_wait_all;

		if (checkpoint_due($sync)) {
			undef $iter;
			reindex_checkpoint($self, $sync);
			goto dedupe_restart;
		}
	}
	goto dedupe_restart if defined($msgids->[++$idx]);

	my $n = delete $sync->{dedupe_cull};
	if (my $pr = $sync->{-opt}->{-progress}) {
		$pr->("culled $n/$candidates candidates ($nr_mid msgids)\n");
	}
	${$sync->{nr}} = 0;
}

sub eidx_sync { # main entry point
	my ($self, $opt) = @_;

	my $warn_cb = $SIG{__WARN__} || \&CORE::warn;
	local $self->{current_info} = '';
	local $SIG{__WARN__} = sub {
		return if PublicInbox::Eml::warn_ignore(@_);
		$warn_cb->($self->{current_info}, ': ', @_);
	};
	$self->idx_init($opt); # acquire lock via V2Writable::_idx_init
	$self->{oidx}->rethread_prepare($opt);
	my $sync = {
		need_checkpoint => \(my $need_checkpoint = 0),
		check_intvl => 10,
		next_check => now() + 10,
		-opt => $opt,
		# DO NOT SET {reindex} here, it's incompatible with reused
		# V2Writable code, reindex is totally different here
		# compared to v1/v2 inboxes because we have multiple histories
		self => $self,
		-regen_fmt => "%u/?\n",
	};
	local $SIG{USR1} = sub { $need_checkpoint = 1 };
	my $quit = PublicInbox::SearchIdx::quit_cb($sync);
	local $SIG{QUIT} = $quit;
	local $SIG{INT} = $quit;
	local $SIG{TERM} = $quit;
	for my $ibx (@{ibx_sorted($self, 'known')}) {
		$ibx->{-ibx_id} //= $self->{oidx}->ibx_id($ibx->eidx_key);
	}

	if (scalar(grep { defined($_->{boost}) } @{$self->{ibx_known}})) {
		$sync->{id2pos} //= prep_id2pos($self);
		$sync->{boost_in_use} = 1;
	}

	if (my $msgids = delete($opt->{dedupe})) {
		local $sync->{checkpoint_unlocks} = 1;
		eidx_dedupe($self, $sync, $msgids);
	}
	if (delete($opt->{reindex})) {
		local $sync->{checkpoint_unlocks} = 1;
		eidx_reindex($self, $sync);
	}

	# don't use $_ here, it'll get clobbered by reindex_checkpoint
	if ($opt->{scan} // 1) {
		for my $ibx (@{ibx_sorted($self, 'active')}) {
			last if $sync->{quit};
			sync_inbox($self, $sync, $ibx);
		}
	}
	$self->{oidx}->rethread_done($opt) unless $sync->{quit};
	eidxq_process($self, $sync) unless $sync->{quit};

	eidxq_release($self);
	done($self);
	$sync; # for eidx_watch
}

sub update_last_commit { # overrides V2Writable
	my ($self, $sync, $stk) = @_;
	my $unit = $sync->{unit} // return;
	my $latest_cmt = $stk ? $stk->{latest_cmt} : ${$sync->{latest_cmt}};
	defined($latest_cmt) or return;
	my $ibx = $sync->{ibx} or die 'BUG: {ibx} missing';
	my $ekey = $ibx->eidx_key;
	my $uv = $ibx->uidvalidity;
	my $epoch = $unit->{epoch};
	my $meta_key;
	my $v = $ibx->version;
	if ($v == 2) {
		die 'No {epoch} for v2 unit' unless defined $epoch;
		$meta_key = "lc-v2:$ekey//$uv;$epoch";
	} elsif ($v == 1) {
		die 'Unexpected {epoch} for v1 unit' if defined $epoch;
		$meta_key = "lc-v1:$ekey//$uv";
	} else {
		die "Unsupported inbox version: $v";
	}
	my $last = $self->{oidx}->eidx_meta($meta_key);
	if (defined $last && is_ancestor($self->git, $last, $latest_cmt)) {
		my @cmd = (qw(rev-list --count), "$last..$latest_cmt");
		chomp(my $n = $unit->{git}->qx(@cmd));
		return if $n ne '' && $n == 0;
	}
	$self->{oidx}->eidx_meta($meta_key, $latest_cmt);
}

sub _idx_init { # with_umask callback
	my ($self, $opt) = @_;
	PublicInbox::V2Writable::_idx_init($self, $opt); # acquires ei.lock
	$self->{midx} = PublicInbox::MiscIdx->new($self);
}

sub symlink_packs ($$) {
	my ($ibx, $pd) = @_;
	my $ret = 0;
	my $glob = "$ibx->{inboxdir}/git/*.git/objects/pack/*.idx";
	for my $idx (bsd_glob($glob, GLOB_NOSORT)) {
		my $src = substr($idx, 0, -length('.idx'));
		my $dst = $pd . substr($src, rindex($src, '/'));
		if (-f "$src.pack" and
				symlink("$src.pack", "$dst.pack") and
				symlink($idx, "$dst.idx") and
				-f $idx) {
			++$ret;
			# .promisor, .bitmap, .rev and .keep are optional
			# XXX should we symlink .keep here?
			for my $s (qw(promisor bitmap rev)) {
				symlink("$src.$s", "$dst.$s") if -f "$src.$s";
			}
		} elsif (!$!{EEXIST}) {
			warn "W: ln -s $src.{pack,idx} => $dst.*: $!\n";
			unlink "$dst.pack", "$dst.idx";
		}
	}
	$ret;
}

sub idx_init { # similar to V2Writable
	my ($self, $opt) = @_;
	return if $self->{idx_shards};

	$self->git->cleanup;
	my $mode = 0644;
	my $ALL = $self->git->{git_dir}; # topdir/ALL.git
	my ($has_new, $alt, $seen, $prune, $prune_nr);
	if ($opt->{-private}) { # LeiStore
		my $local = "$self->{topdir}/local"; # lei/store
		$self->{mg} //= PublicInbox::MultiGit->new($self->{topdir},
							'ALL.git', 'local');
		$mode = 0600;
		unless (-d $ALL) {
			umask 077; # don't bother restoring for lei
			PublicInbox::Import::init_bare($ALL);
			$self->git->qx(qw(config core.sharedRepository 0600));
		}
		($alt, $seen) = $self->{mg}->read_alternates(\$mode);
		$has_new = $self->{mg}->merge_epochs($alt, $seen);
	} else { # extindex has no epochs
		$self->{mg} //= PublicInbox::MultiGit->new($self->{topdir},
							'ALL.git');
		$prune = $opt->{-idx_gc} ? \$prune_nr : undef;
		($alt, $seen) = $self->{mg}->read_alternates(\$mode, $prune);
		PublicInbox::Import::init_bare($ALL);
	}

	# git-multi-pack-index(1) can speed up "git cat-file" startup slightly
	my $git_midx = 0;
	my $pd = "$ALL/objects/pack";
	if (opendir(my $dh, $pd)) { # drop stale symlinks
		while (defined(my $dn = readdir($dh))) {
			if ($dn =~ /\.(?:idx|pack|promisor|bitmap|rev)\z/) {
				my $f = "$pd/$dn";
				unlink($f) if -l $f && !-e $f;
			}
		}
	} elsif ($!{ENOENT}) {
		mkdir($pd) or die "mkdir($pd): $!";
	} else {
		die "opendir($pd): $!";
	}
	my $new = '';
	for my $ibx (@{ibx_sorted($self, 'active')}) {
		# create symlinks for multi-pack-index
		$git_midx += symlink_packs($ibx, $pd);
		# add new lines to our alternates file
		my $d = $ibx->git->{git_dir} . '/objects';
		next if exists $alt->{$d};
		if (my @st = stat($d)) {
			next if $seen->{"$st[0]\0$st[1]"}++;
		} else {
			warn "W: stat($d) failed (from $ibx->{inboxdir}): $!\n";
			next if $opt->{-idx_gc};
		}
		$new .= "$d\n";
	}
	($has_new || $prune_nr || $new ne '') and
		$self->{mg}->write_alternates($mode, $alt, $new);
	$git_midx and $self->with_umask(sub {
		my @cmd = ('multi-pack-index');
		push @cmd, '--no-progress' if ($opt->{quiet}//0) > 1;
		my $lk = $self->lock_for_scope;
		system('git', "--git-dir=$ALL", @cmd, 'write');
		# ignore errors, fairly new command, may not exist
	});
	$self->parallel_init($self->{indexlevel});
	$self->with_umask(\&_idx_init, $self, $opt);
	$self->{oidx}->begin_lazy;
	$self->{oidx}->eidx_prep;
	$self->{midx}->create_xdb if $new ne '';
}

sub _watch_commit { # PublicInbox::DS::add_timer callback
	my ($self) = @_;
	delete $self->{-commit_timer};
	eidxq_process($self, $self->{-watch_sync});
	eidxq_release($self);
	my $fmt = delete $self->{-watch_sync}->{-regen_fmt};
	reindex_checkpoint($self, $self->{-watch_sync});
	$self->{-watch_sync}->{-regen_fmt} = $fmt;

	# call event_step => done unless commit_timer is armed
	PublicInbox::DS::requeue($self);
}

sub on_inbox_unlock { # called by PublicInbox::InboxIdle
	my ($self, $ibx) = @_;
	my $opt = $self->{-watch_sync}->{-opt};
	my $pr = $opt->{-progress};
	my $ekey = $ibx->eidx_key;
	local $0 = "sync $ekey";
	$pr->("indexing $ekey\n") if $pr;
	$self->idx_init($opt);
	sync_inbox($self, $self->{-watch_sync}, $ibx);
	$self->{-commit_timer} //= add_timer($opt->{'commit-interval'} // 10,
					\&_watch_commit, $self);
}

sub eidx_reload { # -extindex --watch SIGHUP handler
	my ($self, $idler) = @_;
	if ($self->{cfg}) {
		my $pr = $self->{-watch_sync}->{-opt}->{-progress};
		$pr->('reloading ...') if $pr;
		delete $self->{-resync_queue};
		delete $self->{-ibx_ary_known};
		delete $self->{-ibx_ary_active};
		$self->{ibx_known} = [];
		$self->{ibx_active} = [];
		%{$self->{ibx_map}} = ();
		delete $self->{-watch_sync}->{id2pos};
		my $cfg = PublicInbox::Config->new;
		attach_config($self, $cfg);
		$idler->refresh($cfg);
		$pr->(" done\n") if $pr;
	} else {
		warn "reload not supported without --all\n";
	}
}

sub eidx_resync_start ($) { # -extindex --watch SIGUSR1 handler
	my ($self) = @_;
	$self->{-resync_queue} //= [ @{ibx_sorted($self, 'active')} ];
	PublicInbox::DS::requeue($self); # trigger our ->event_step
}

sub event_step { # PublicInbox::DS::requeue callback
	my ($self) = @_;
	if (my $resync_queue = $self->{-resync_queue}) {
		if (my $ibx = shift(@$resync_queue)) {
			on_inbox_unlock($self, $ibx);
			PublicInbox::DS::requeue($self);
		} else {
			delete $self->{-resync_queue};
			_watch_commit($self);
		}
	} else {
		done($self) unless $self->{-commit_timer};
	}
}

sub eidx_watch { # public-inbox-extindex --watch main loop
	my ($self, $opt) = @_;
	local @SIG{keys %SIG} = values %SIG;
	for my $sig (qw(HUP USR1 TSTP QUIT INT TERM)) {
		$SIG{$sig} = sub { warn "SIG$sig ignored while scanning\n" };
	}
	require PublicInbox::InboxIdle;
	require PublicInbox::DS;
	require PublicInbox::Syscall;
	require PublicInbox::Sigfd;
	my $idler = PublicInbox::InboxIdle->new($self->{cfg});
	if (!$self->{cfg}) {
		$idler->watch_inbox($_) for (@{ibx_sorted($self, 'active')});
	}
	for my $ibx (@{ibx_sorted($self, 'active')}) {
		$ibx->subscribe_unlock(__PACKAGE__, $self)
	}
	my $pr = $opt->{-progress};
	$pr->("performing initial scan ...\n") if $pr;
	my $sync = eidx_sync($self, $opt); # initial sync
	return if $sync->{quit};
	my $oldset = PublicInbox::DS::block_signals();
	local $self->{current_info} = '';
	my $cb = $SIG{__WARN__} || \&CORE::warn;
	local $SIG{__WARN__} = sub {
		return if PublicInbox::Eml::warn_ignore(@_);
		$cb->($self->{current_info}, ': ', @_);
	};
	my $sig = {
		HUP => sub { eidx_reload($self, $idler) },
		USR1 => sub { eidx_resync_start($self) },
		TSTP => sub { kill('STOP', $$) },
	};
	my $quit = PublicInbox::SearchIdx::quit_cb($sync);
	$sig->{QUIT} = $sig->{INT} = $sig->{TERM} = $quit;
	local $self->{-watch_sync} = $sync; # for ->on_inbox_unlock
	PublicInbox::DS->SetPostLoopCallback(sub { !$sync->{quit} });
	$pr->("initial scan complete, entering event loop\n") if $pr;
	# calls InboxIdle->event_step:
	PublicInbox::DS::event_loop($sig, $oldset);
	done($self);
}

no warnings 'once';
*done = \&PublicInbox::V2Writable::done;
*with_umask = \&PublicInbox::InboxWritable::with_umask;
*parallel_init = \&PublicInbox::V2Writable::parallel_init;
*nproc_shards = \&PublicInbox::V2Writable::nproc_shards;
*sync_prepare = \&PublicInbox::V2Writable::sync_prepare;
*index_todo = \&PublicInbox::V2Writable::index_todo;
*count_shards = \&PublicInbox::V2Writable::count_shards;
*atfork_child = \&PublicInbox::V2Writable::atfork_child;
*idx_shard = \&PublicInbox::V2Writable::idx_shard;
*reindex_checkpoint = \&PublicInbox::V2Writable::reindex_checkpoint;
*checkpoint = \&PublicInbox::V2Writable::checkpoint;

1;
