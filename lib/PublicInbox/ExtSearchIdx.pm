# Copyright (C) 2020 all contributors <meta@public-inbox.org>
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
use Sys::Hostname qw(hostname);
use POSIX qw(strftime);
use PublicInbox::Search;
use PublicInbox::SearchIdx qw(crlf_adjust prepare_stack is_ancestor
	is_bad_blob);
use PublicInbox::OverIdx;
use PublicInbox::MiscIdx;
use PublicInbox::MID qw(mids);
use PublicInbox::V2Writable;
use PublicInbox::InboxWritable;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::Eml;
use File::Spec;
use PublicInbox::DS qw(now);
use DBI qw(:sql_types); # SQL_BLOB

sub new {
	my (undef, $dir, $opt) = @_;
	$dir = File::Spec->canonpath($dir);
	my $l = $opt->{indexlevel} // 'full';
	$l !~ $PublicInbox::SearchIdx::INDEXLEVELS and
		die "invalid indexlevel=$l\n";
	$l eq 'basic' and die "E: indexlevel=basic not yet supported\n";
	my $self = bless {
		xpfx => "$dir/ei".PublicInbox::Search::SCHEMA_VERSION,
		topdir => $dir,
		creat => $opt->{creat},
		ibx_map => {}, # (newsgroup//inboxdir) => $ibx
		ibx_list => [],
		indexlevel => $l,
		transact_bytes => 0,
		total_bytes => 0,
		current_info => '',
		parallel => 1,
		lock_path => "$dir/ei.lock",
	}, __PACKAGE__;
	$self->{shards} = $self->count_shards || nproc_shards($opt->{creat});
	my $oidx = PublicInbox::OverIdx->new("$self->{xpfx}/over.sqlite3");
	$oidx->{-no_fsync} = 1 if $opt->{-no_fsync};
	$self->{oidx} = $oidx;
	$self
}

sub attach_inbox {
	my ($self, $ibx) = @_;
	my $key = $ibx->eidx_key;
	if (!$ibx->over || !$ibx->mm) {
		warn "W: skipping $key (unindexed)\n";
		return;
	}
	if (!defined($ibx->uidvalidity)) {
		warn "W: skipping $key (no UIDVALIDITY)\n";
		return;
	}
	my $ibxdir = File::Spec->canonpath($ibx->{inboxdir});
	if ($ibxdir ne $ibx->{inboxdir}) {
		warn "W: `$ibx->{inboxdir}' canonicalized to `$ibxdir'\n";
		$ibx->{inboxdir} = $ibxdir;
	}
	$self->{ibx_map}->{$key} //= do {
		push @{$self->{ibx_list}}, $ibx;
		$ibx;
	}
}

sub _ibx_attach { # each_inbox callback
	my ($ibx, $self) = @_;
	attach_inbox($self, $ibx);
}

sub attach_config {
	my ($self, $cfg) = @_;
	$self->{cfg} = $cfg;
	$cfg->each_inbox(\&_ibx_attach, $self);
}

sub check_batch_limit ($) {
	my ($req) = @_;
	my $self = $req->{self};
	my $new_smsg = $req->{new_smsg};

	# {raw_bytes} may be unset, so just use {bytes}
	my $n = $self->{transact_bytes} += $new_smsg->{bytes};

	# set flag for PublicInbox::V2Writable::index_todo:
	${$req->{need_checkpoint}} = 1 if $n >= $self->{batch_bytes};
}

sub do_xpost ($$) {
	my ($req, $smsg) = @_;
	my $self = $req->{self};
	my $docid = $smsg->{num};
	my $idx = $self->idx_shard($docid);
	my $oid = $req->{oid};
	my $xibx = $req->{ibx};
	my $eml = $req->{eml};
	my $eidx_key = $xibx->eidx_key;
	if (my $new_smsg = $req->{new_smsg}) { # 'm' on cross-posted message
		my $xnum = $req->{xnum};
		$self->{oidx}->add_xref3($docid, $xnum, $oid, $eidx_key);
		$idx->shard_add_eidx_info($docid, $eidx_key, $eml);
		check_batch_limit($req);
	} else { # 'd'
		my $rm_eidx_info;
		my $nr = $self->{oidx}->remove_xref3($docid, $oid, $eidx_key,
							\$rm_eidx_info);
		if ($nr == 0) {
			$self->{oidx}->eidxq_del($docid);
			$idx->shard_remove($docid);
		} elsif ($rm_eidx_info) {
			$idx->shard_remove_eidx_info($docid, $eidx_key, $eml);
			$self->{oidx}->eidxq_add($docid); # yes, add
		}
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
	$idx->index_raw(undef, $eml, $new_smsg, $ibx->eidx_key);
	check_batch_limit($req);
}

sub do_finalize ($) {
	my ($req) = @_;
	if (my $indexed = $req->{indexed}) {
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
			delete $req->{cur_smsg};
			delete $req->{next_arg};
		}
		my $mid = shift(@{$req->{mids}});
		last unless defined $mid;
		my ($id, $prev);
		$req->{next_arg} = [ $mid, \$id, \$prev ];
		# loop again
	}
	do_finalize($req);
}

sub _blob_missing ($) { # called when req->{cur_smsg}->{blob} is bad
	my ($req) = @_;
	my $smsg = $req->{cur_smsg} or die 'BUG: {cur_smsg} missing';
	my $self = $req->{self};
	my $xref3 = $self->{oidx}->get_xref3($smsg->{num});
	my @keep = grep(!/:$smsg->{blob}\z/, @$xref3);
	if (@keep) {
		$keep[0] =~ /:([a-f0-9]{40,}+)\z/ or
			die "BUG: xref $keep[0] has no OID";
		my $oidhex = $1;
		$self->{oidx}->remove_xref3($smsg->{num}, $smsg->{blob});
		my $upd = $self->{oidx}->update_blob($smsg, $oidhex);
		my $saved = $self->{oidx}->get_art($smsg->{num});
	} else {
		$self->{oidx}->delete_by_num($smsg->{num});
	}
}

sub ck_existing { # git->cat_async callback
	my ($bref, $oid, $type, $size, $req) = @_;
	my $smsg = $req->{cur_smsg} or die 'BUG: {cur_smsg} missing';
	if ($type eq 'missing') {
		_blob_missing($req);
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
sub cur_ibx_xnum ($$) {
	my ($req, $bref) = @_;
	my $ibx = $req->{ibx} or die 'BUG: current {ibx} missing';

	$req->{eml} = PublicInbox::Eml->new($bref);
	$req->{chash} = content_hash($req->{eml});
	$req->{mids} = mids($req->{eml});
	my @q = @{$req->{mids}}; # copy
	while (defined(my $mid = shift @q)) {
		my ($id, $prev);
		while (my $x = $ibx->over->next_by_mid($mid, \$id, \$prev)) {
			return $x->{num} if $x->{blob} eq $req->{oid};
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
	$new_smsg->{bytes} = $size + crlf_adjust($$bref);
	defined($req->{xnum} = cur_ibx_xnum($req, $bref)) or return;
	++${$req->{nr}};
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

sub _sync_inbox ($$$) {
	my ($self, $sync, $ibx) = @_;
	$sync->{ibx} = $ibx;
	$sync->{nr} = \(my $nr = 0);
	my $v = $ibx->version;
	my $ekey = $ibx->eidx_key;
	if ($v == 2) {
		$sync->{epoch_max} = $ibx->max_git_epoch // return;
		sync_prepare($self, $sync); # or return # TODO: once MiscIdx is stable
	} elsif ($v == 1) {
		my $uv = $ibx->uidvalidity;
		my $lc = $self->{oidx}->eidx_meta("lc-v1:$ekey//$uv");
		my $head = $ibx->mm->last_commit;
		unless (defined $head) {
			warn "E: $ibx->{inboxdir} is not indexed\n";
			return;
		}
		my $stk = prepare_stack($sync, $lc ? "$lc..$head" : $head);
		my $unit = { stack => $stk, git => $ibx->git };
		push @{$sync->{todo}}, $unit;
	} else {
		warn "E: $ekey unsupported inbox version (v$v)\n";
		return;
	}
	for my $unit (@{delete($sync->{todo}) // []}) {
		last if $sync->{quit};
		index_todo($self, $sync, $unit);
	}
	$self->{midx}->index_ibx($ibx) unless $sync->{quit};
	$ibx->git->cleanup; # done with this inbox, now
}

sub gc_unref_doc ($$$$) {
	my ($self, $ibx_id, $eidx_key, $docid) = @_;
	my $dbh = $self->{oidx}->dbh;

	# for debug/info purposes, oids may no longer be accessible
	my $sth = $dbh->prepare_cached(<<'', undef, 1);
SELECT oidbin FROM xref3 WHERE docid = ? AND ibx_id = ?

	$sth->execute($docid, $ibx_id);
	my @oid = map { unpack('H*', $_->[0]) } @{$sth->fetchall_arrayref};

	$dbh->prepare_cached(<<'')->execute($docid, $ibx_id);
DELETE FROM xref3 WHERE docid = ? AND ibx_id = ?

	my $remain = $self->{oidx}->get_xref3($docid);
	if (scalar(@$remain)) {
		$self->{oidx}->eidxq_add($docid); # enqueue for reindex
		for my $oid (@oid) {
			warn "I: unref #$docid $eidx_key $oid\n";
		}
	} else {
		warn "I: remove #$docid $eidx_key @oid\n";
		$self->idx_shard($docid)->shard_remove($docid);
	}
}

sub eidx_gc {
	my ($self, $opt) = @_;
	$self->{cfg} or die "E: GC requires ->attach_config\n";
	$opt->{-idx_gc} = 1;
	$self->idx_init($opt); # acquire lock via V2Writable::_idx_init

	my $dbh = $self->{oidx}->dbh;
	my $x3_doc = $dbh->prepare('SELECT docid FROM xref3 WHERE ibx_id = ?');
	my $ibx_ck = $dbh->prepare('SELECT ibx_id,eidx_key FROM inboxes');
	my $lc_i = $dbh->prepare('SELECT key FROM eidx_meta WHERE key LIKE ?');

	$ibx_ck->execute;
	while (my ($ibx_id, $eidx_key) = $ibx_ck->fetchrow_array) {
		next if $self->{ibx_map}->{$eidx_key};
		$self->{midx}->remove_eidx_key($eidx_key);
		warn "I: deleting messages for $eidx_key...\n";
		$x3_doc->execute($ibx_id);
		while (defined(my $docid = $x3_doc->fetchrow_array)) {
			gc_unref_doc($self, $ibx_id, $eidx_key, $docid);
		}
		$dbh->prepare_cached(<<'')->execute($ibx_id);
DELETE FROM inboxes WHERE ibx_id = ?

		# drop last_commit info
		my $pat = $eidx_key;
		$pat =~ s/([_%])/\\$1/g;
		$lc_i->execute("lc-%:$pat//%");
		while (my ($key) = $lc_i->fetchrow_array) {
			next if $key !~ m!\Alc-v[1-9]+:\Q$eidx_key\E//!;
			warn "I: removing $key\n";
			$dbh->prepare_cached(<<'')->execute($key);
DELETE FROM eidx_meta WHERE key = ?

		}

		warn "I: $eidx_key removed\n";
	}

	# it's not real unless it's in `over', we use parallelism here,
	# shards will be reading directly from over, so commit
	$self->{oidx}->commit_lazy;
	$self->{oidx}->begin_lazy;

	for my $idx (@{$self->{idx_shards}}) {
		warn "I: cleaning up shard #$idx->{shard}\n";
		$idx->shard_over_check($self->{oidx});
	}
	my $nr = $dbh->do(<<'');
DELETE FROM xref3 WHERE docid NOT IN (SELECT num FROM over)

	warn "I: eliminated $nr stale xref3 entries\n" if $nr != 0;

	done($self);
}

sub _ibx_for ($$$) {
	my ($self, $sync, $smsg) = @_;
	my $ibx_id = delete($smsg->{ibx_id}) // die '{ibx_id} unset';
	my $pos = $sync->{id2pos}->{$ibx_id} // die "$ibx_id no pos";
	$self->{ibx_list}->[$pos] // die "BUG: ibx for $smsg->{blob} not mapped"
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
	$idx->index_raw(undef, $eml, $smsg, $ibx->eidx_key);
	for my $x (reverse @$stable) {
		$ibx = _ibx_for($self, $sync, $x);
		my $hdr = delete $x->{hdr} // die 'BUG: no {hdr}';
		$idx->shard_add_eidx_info($docid, $ibx->eidx_key, $hdr);
	}
	return if $nr == 1; # likely, all good

	warn "W: #$docid split into $nr due to deduplication change\n";
	my @todo;
	for my $ary (values %$by_chash) {
		for my $x (reverse @$ary) {
			warn "removing #$docid xref3 $x->{blob}\n";
			my $n = $self->{oidx}->remove_xref3($docid, $x->{blob});
			die "BUG: $x->{blob} invalidated #$docid" if $n == 0;
		}
		my $x = pop(@$ary) // die "BUG: #$docid {by_chash} empty";
		$x->{num} = delete($x->{xnum}) // die '{xnum} unset';
		$ibx = _ibx_for($self, $sync, $x);
		my $e = $ibx->over->get_art($x->{num});
		$e->{blob} eq $x->{blob} or die <<EOF;
$x->{blob} != $e->{blob} (${\$ibx->eidx_key}:$e->{num});
EOF
		push @todo, $ibx, $e;
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
		my $remain = $self->{oidx}->remove_xref3($docid, $expect_oid);
		if ($remain == 0) {
			warn "W: #$docid gone or corrupted\n";
			$self->idx_shard($docid)->shard_remove($docid);
		} elsif (my $next_oid = $req->{xr3r}->[++$req->{ix}]->[2]) {
			$self->git->cat_async($next_oid, \&_reindex_oid, $req);
		} else {
			warn "BUG: #$docid gone (UNEXPECTED)\n";
			$self->idx_shard($docid)->shard_remove($docid);
		}
		return;
	}
	my $ci = $self->{current_info};
	local $self->{current_info} = "$ci #$docid $oid";
	my $re_smsg = bless { blob => $oid }, 'PublicInbox::Smsg';
	$re_smsg->{bytes} = $size + crlf_adjust($$bref);
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

		$self->{oidx}->delete_by_num($docid);
		$self->idx_shard($docid)->shard_remove($docid);
		return;
	}

	# we sort {xr3r} in the reverse order of {ibx_list} so we can
	# hit the common case in _reindex_finalize without rereading
	# from git (or holding multiple messages in memory).
	my $id2pos = $sync->{id2pos}; # index in {ibx_list}
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
		# hostid(1) is in GNU coreutils, kern.hostid is FreeBSD
		chomp($m ||= `hostid` || `sysctl -n kern.hostid`);
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
	my $t = strftime('%Y-%m-%d %k:%M:%S', gmtime($time));
	if ($euid == $> && $ident eq host_ident) {
		if (kill(0, $pid)) {
			warn <<EOM; return;
I: PID:$pid (re)indexing Xapian since $t, it will continue our work
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

sub eidxq_process ($$) { # for reindexing
	my ($self, $sync) = @_;

	return unless eidxq_lock_acquire($self);
	my $dbh = $self->{oidx}->dbh;
	my $tot = $dbh->selectrow_array('SELECT COUNT(*) FROM eidxq') or return;
	${$sync->{nr}} = 0;
	$sync->{-regen_fmt} = "%u/$tot\n";
	my $pr = $sync->{-opt}->{-progress};
	if ($pr) {
		my $min = $dbh->selectrow_array('SELECT MIN(docid) FROM eidxq');
		my $max = $dbh->selectrow_array('SELECT MAX(docid) FROM eidxq');
		$pr->("Xapian indexing $min..$max (total=$tot)\n");
	}
	$sync->{id2pos} //= do {
		my %id2pos;
		my $pos = 0;
		$id2pos{$_->{-ibx_id}} = $pos++ for @{$self->{ibx_list}};
		\%id2pos;
	};
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
	$new_smsg->{bytes} = $size + crlf_adjust($$bref);
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

sub _reindex_check_unseen ($$$) {
	my ($self, $sync, $ibx) = @_;
	my $ibx_id = $ibx->{-ibx_id};
	my $slice = 1000;
	my ($beg, $end) = (1, $slice);

	# first, check if we missed any messages in target $ibx
	my $msgs;
	my $pr = $sync->{-opt}->{-progress};
	my $ekey = $ibx->eidx_key;
	$sync->{-regen_fmt} = "$ekey checking unseen %u/".$ibx->over->max."\n";
	${$sync->{nr}} = 0;

	while (scalar(@{$msgs = $ibx->over->query_xover($beg, $end)})) {
		${$sync->{nr}} = $beg;
		$beg = $msgs->[-1]->{num} + 1;
		$end = $beg + $slice;
		if (checkpoint_due($sync)) {
			reindex_checkpoint($self, $sync); # release lock
		}

		my $inx3 = $self->{oidx}->dbh->prepare_cached(<<'', undef, 1);
SELECT DISTINCT(docid) FROM xref3 WHERE
ibx_id = ? AND xnum = ? AND oidbin = ?

		for my $xsmsg (@$msgs) {
			my $oidbin = pack('H*', $xsmsg->{blob});
			$inx3->bind_param(1, $ibx_id);
			$inx3->bind_param(2, $xsmsg->{num});
			$inx3->bind_param(3, $oidbin, SQL_BLOB);
			$inx3->execute;
			my $docids = $inx3->fetchall_arrayref;
			# index messages which were totally missed
			# the first time around ASAP:
			if (scalar(@$docids) == 0) {
				reindex_unseen($self, $sync, $ibx, $xsmsg);
			} else { # already seen, reindex later
				for my $r (@$docids) {
					$self->{oidx}->eidxq_add($r->[0]);
				}
			}
			last if $sync->{quit};
		}
		last if $sync->{quit};
	}
}

sub _reindex_check_stale ($$$) {
	my ($self, $sync, $ibx) = @_;
	my $min = 0;
	my $pr = $sync->{-opt}->{-progress};
	my $fetching;
	my $ekey = $ibx->eidx_key;
	$sync->{-regen_fmt} =
			"$ekey check stale/missing %u/".$ibx->over->max."\n";
	${$sync->{nr}} = 0;
	do {
		if (checkpoint_due($sync)) {
			reindex_checkpoint($self, $sync); # release lock
		}
		# now, check if there's stale xrefs
		my $iter = $self->{oidx}->dbh->prepare_cached(<<'', undef, 1);
SELECT docid,xnum,oidbin FROM xref3 WHERE ibx_id = ? AND docid > ?
ORDER BY docid,xnum ASC LIMIT 10000

		$iter->execute($ibx->{-ibx_id}, $min);
		$fetching = undef;

		while (my ($docid, $xnum, $oidbin) = $iter->fetchrow_array) {
			return if $sync->{quit};
			${$sync->{nr}} = $xnum;

			$fetching = $min = $docid;
			my $smsg = $ibx->over->get_art($xnum);
			my $oidhex = unpack('H*', $oidbin);
			my $err;
			if (!$smsg) {
				$err = 'stale';
			} elsif ($smsg->{blob} ne $oidhex) {
				$err = "mismatch (!= $smsg->{blob})";
			} else {
				next; # likely, all good
			}
			# current_info already has eidx_key
			warn "$xnum:$oidhex (#$docid): $err\n";
			my $del = $self->{oidx}->dbh->prepare_cached(<<'');
DELETE FROM xref3 WHERE ibx_id = ? AND xnum = ? AND oidbin = ?

			$del->bind_param(1, $ibx->{-ibx_id});
			$del->bind_param(2, $xnum);
			$del->bind_param(3, $oidbin, SQL_BLOB);
			$del->execute;

			# get_xref3 over-fetches, but this is a rare path:
			my $xr3 = $self->{oidx}->get_xref3($docid);
			my $idx = $self->idx_shard($docid);
			if (scalar(@$xr3) == 0) { # all gone
				$self->{oidx}->delete_by_num($docid);
				$self->{oidx}->eidxq_del($docid);
				$idx->shard_remove($docid);
			} else { # enqueue for reindex of remaining messages
				$idx->shard_remove_eidx_info($docid,
							$ibx->eidx_key);
				$self->{oidx}->eidxq_add($docid); # yes, add
			}
		}
	} while (defined $fetching);
}

sub _reindex_inbox ($$$) {
	my ($self, $sync, $ibx) = @_;
	local $self->{current_info} = $ibx->eidx_key;
	_reindex_check_unseen($self, $sync, $ibx);
	_reindex_check_stale($self, $sync, $ibx) unless $sync->{quit};
	delete @$ibx{qw(over mm search git)}; # won't need these for a bit
}

sub eidx_reindex {
	my ($self, $sync) = @_;

	# acquire eidxq_lock early because full reindex takes forever
	# and incremental -extindex processes can run during our checkpoints
	if (!eidxq_lock_acquire($self)) {
		warn "E: aborting --reindex\n";
		return;
	}
	for my $ibx (@{$self->{ibx_list}}) {
		_reindex_inbox($self, $sync, $ibx);
		last if $sync->{quit};
	}
	$self->git->async_wait_all; # ensure eidxq gets filled completely
	eidxq_process($self, $sync) unless $sync->{quit};
}

sub eidx_sync { # main entry point
	my ($self, $opt) = @_;

	my $warn_cb = $SIG{__WARN__} || sub { print STDERR @_ };
	local $self->{current_info} = '';
	local $SIG{__WARN__} = sub {
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
	for my $ibx (@{$self->{ibx_list}}) {
		$ibx->{-ibx_id} //= $self->{oidx}->ibx_id($ibx->eidx_key);
	}
	if (delete($opt->{reindex})) {
		$sync->{checkpoint_unlocks} = 1;
		eidx_reindex($self, $sync);
	}

	# don't use $_ here, it'll get clobbered by reindex_checkpoint
	for my $ibx (@{$self->{ibx_list}}) {
		last if $sync->{quit};
		_sync_inbox($self, $sync, $ibx);
	}
	$self->{oidx}->rethread_done($opt) unless $sync->{quit};
	eidxq_process($self, $sync) unless $sync->{quit};

	eidxq_release($self);
	PublicInbox::V2Writable::done($self);
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
	PublicInbox::V2Writable::_idx_init($self, $opt);
	$self->{midx} = PublicInbox::MiscIdx->new($self);
}

sub idx_init { # similar to V2Writable
	my ($self, $opt) = @_;
	return if $self->{idx_shards};

	$self->git->cleanup;

	my $ALL = $self->git->{git_dir}; # ALL.git
	PublicInbox::Import::init_bare($ALL) unless -d $ALL;
	my $info_dir = "$ALL/objects/info";
	my $alt = "$info_dir/alternates";
	my $mode = 0644;
	my (@old, @new, %seen); # seen: st_dev + st_ino
	if (-e $alt) {
		open(my $fh, '<', $alt) or die "open $alt: $!";
		$mode = (stat($fh))[2] & 07777;
		while (my $line = <$fh>) {
			chomp(my $d = $line);
			if (my @st = stat($d)) {
				next if $seen{"$st[0]\0$st[1]"}++;
			} else {
				warn "W: stat($d) failed (from $alt): $!\n";
				next if $opt->{-idx_gc};
			}
			push @old, $line;
		}
	}
	for my $ibx (@{$self->{ibx_list}}) {
		my $line = $ibx->git->{git_dir} . "/objects\n";
		chomp(my $d = $line);
		if (my @st = stat($d)) {
			next if $seen{"$st[0]\0$st[1]"}++;
		} else {
			warn "W: stat($d) failed (from $ibx->{inboxdir}): $!\n";
			next if $opt->{-idx_gc};
		}
		push @new, $line;
	}
	if (scalar @new) {
		push @old, @new;
		my $o = \@old;
		PublicInbox::V2Writable::write_alternates($info_dir, $mode, $o);
	}
	$self->parallel_init($self->{indexlevel});
	$self->umask_prepare;
	$self->with_umask(\&_idx_init, $self, $opt);
	$self->{oidx}->begin_lazy;
	$self->{oidx}->eidx_prep;
	$self->{midx}->begin_txn;
}

no warnings 'once';
*done = \&PublicInbox::V2Writable::done;
*umask_prepare = \&PublicInbox::InboxWritable::umask_prepare;
*with_umask = \&PublicInbox::InboxWritable::with_umask;
*parallel_init = \&PublicInbox::V2Writable::parallel_init;
*nproc_shards = \&PublicInbox::V2Writable::nproc_shards;
*sync_prepare = \&PublicInbox::V2Writable::sync_prepare;
*index_todo = \&PublicInbox::V2Writable::index_todo;
*count_shards = \&PublicInbox::V2Writable::count_shards;
*atfork_child = \&PublicInbox::V2Writable::atfork_child;
*idx_shard = \&PublicInbox::V2Writable::idx_shard;
*reindex_checkpoint = \&PublicInbox::V2Writable::reindex_checkpoint;

1;
