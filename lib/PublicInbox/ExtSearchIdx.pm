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
use PublicInbox::Search;
use PublicInbox::SearchIdx qw(crlf_adjust prepare_stack is_ancestor);
use PublicInbox::OverIdx;
use PublicInbox::MiscIdx;
use PublicInbox::MID qw(mids);
use PublicInbox::V2Writable;
use PublicInbox::InboxWritable;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::Eml;
use File::Spec;

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
	$ibx = PublicInbox::InboxWritable->new($ibx);
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
	$ibx = PublicInbox::InboxWritable->new($ibx);
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
	$cfg->each_inbox(\&_ibx_attach, $self);
}

sub git_blob_digest ($) {
	my ($bref) = @_;
	my $dig = Digest::SHA->new(1); # XXX SHA256 later
	$dig->add('blob '.length($$bref)."\0");
	$dig->add($$bref);
	$dig;
}

sub is_bad_blob ($$$$) {
	my ($oid, $type, $size, $expect_oid) = @_;
	if ($type ne 'blob') {
		carp "W: $expect_oid is not a blob (type=$type)";
		return 1;
	}
	croak "BUG: $oid != $expect_oid" if $oid ne $expect_oid;
	$size == 0 ? 1 : 0; # size == 0 means purged
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
		$idx->shard_add_eidx_info($docid, $oid, $xibx, $eml);
		check_batch_limit($req);
	} else { # 'd'
		my $rm_eidx_info;
		my $nr = $self->{oidx}->remove_xref3($docid, $oid, $eidx_key,
							\$rm_eidx_info);
		if ($nr == 0) {
			$idx->shard_remove($oid, $docid);
		} elsif ($rm_eidx_info) {
			$idx->shard_remove_eidx_info($docid, $oid, $xibx, $eml);
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
	$idx->index_raw(undef, $eml, $new_smsg, $ibx);
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
	my $self = $req->{self};
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

	# XXX overkill?
	git_blob_digest($bref)->hexdigest eq $req->{oid} or die
		"BUG: blob mismatch $req->{oid}";

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
		my $epoch_max;
		defined($ibx->git_dir_latest(\$epoch_max)) or return;
		$sync->{epoch_max} = $epoch_max;
		sync_prepare($self, $sync); # or return # TODO: once MiscIdx is stable
	} elsif ($v == 1) {
		my $uv = $ibx->uidvalidity;
		my $lc = $self->{oidx}->eidx_meta("lc-v1:$ekey//$uv");
		my $stk = prepare_stack($sync, $lc ? "$lc..HEAD" : 'HEAD');
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

sub eidx_sync { # main entry point
	my ($self, $opt) = @_;
	$self->idx_init($opt); # acquire lock via V2Writable::_idx_init
	$self->{oidx}->rethread_prepare($opt);

	my $warn_cb = $SIG{__WARN__} || sub { print STDERR @_ };
	local $self->{current_info} = '';
	local $SIG{__WARN__} = sub {
		$warn_cb->($self->{current_info}, ': ', @_);
	};
	my $sync = {
		need_checkpoint => \(my $need_checkpoint = 0),
		reindex => $opt->{reindex},
		-opt => $opt,
		self => $self,
		-regen_fmt => "%u/?\n",
	};
	local $SIG{USR1} = sub { $need_checkpoint = 1 };
	my $quit = PublicInbox::SearchIdx::quit_cb($sync);
	local $SIG{QUIT} = $quit;
	local $SIG{INT} = $quit;
	local $SIG{TERM} = $quit;

	# don't use $_ here, it'll get clobbered by reindex_checkpoint
	for my $ibx (@{$self->{ibx_list}}) {
		last if $sync->{quit};
		_sync_inbox($self, $sync, $ibx);
	}
	$self->{oidx}->rethread_done($opt) unless $sync->{quit};

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

1;
