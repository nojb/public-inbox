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
use PublicInbox::SearchIdx qw(crlf_adjust);
use PublicInbox::OverIdx;
use PublicInbox::V2Writable;
use PublicInbox::InboxWritable;
use PublicInbox::Eml;
use File::Spec;

sub new {
	my (undef, $dir, $opt, $shard) = @_;
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

sub do_xpost ($$) {
	my ($req, $smsg) = @_;
	my $self = $req->{self};
	my $docid = $smsg->{num};
	my $idx = $self->idx_shard($docid);
	my $oid = $req->{oid};
	my $xibx = $req->{ibx};
	my $eml = $req->{eml};
	if (my $new_smsg = $req->{new_smsg}) { # 'm' on cross-posted message
		my $xnum = $req->{xnum};
		$idx->shard_add_xref3($docid, $xnum, $oid, $xibx, $eml);
	} else { # 'd'
		$idx->shard_remove_xref3($docid, $oid, $xibx, $eml);
	}
}

# called by V2Writable::sync_prepare
sub artnum_max { $_[0]->{oidx}->get_counter('eidx_docid') }

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
	$idx->index_raw(undef, $eml, $new_smsg, $req->{ibx});
}

sub do_finalize ($) {
	my ($req) = @_;
	if (my $indexed = $req->{indexed}) {
		do_xpost($req, $_) for @$indexed;
	} elsif (exists $req->{new_smsg}) { # totally unseen messsage
		index_unseen($req);
	} else {
		warn "W: ignoring delete $req->{oid} (not found)\n";
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

sub ck_existing { # git->cat_async callback
	my ($bref, $oid, $type, $size, $req) = @_;
	my $smsg = $req->{cur_smsg} or die 'BUG: {cur_smsg} missing';
	return if is_bad_blob($oid, $type, $size, $smsg->{blob});
	my $cur = PublicInbox::Eml->new($bref);
	if (content_digest($cur) eq $req->{chash}) {
		push @{$req->{indexed}}, $smsg; # for do_xpost
	} # else { index_unseen later }
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
	return if is_bad_blob($oid, $type, $size, $req->{oid});
	my $new_smsg = $req->{new_smsg} = bless {
		blob => $oid,
	}, 'PublicInbox::Smsg';
	$new_smsg->{bytes} = $size + crlf_adjust($$bref);
	defined($req->{xnum} = cur_ibx_xnum($req, $bref)) or return;
	do_step($req);
}

sub unindex_oid { # git->cat_async callback for 'd'
	my ($bref, $oid, $type, $size, $req) = @_;
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
	my ($self, $opt, $ibx) = @_;
	my $sync = {
		need_checkpoint => \(my $bool = 0),
		reindex => $opt->{reindex},
		-opt => $opt,
		self => $self,
		ibx => $ibx,
	};
	my $v = $ibx->version;
	my $ekey = $ibx->eidx_key;
	if ($v == 2) {
		my $epoch_max;
		defined($ibx->git_dir_latest(\$epoch_max)) or return;
		$sync->{epoch_max} = $epoch_max;
		sync_prepare($self, $sync) or return;
		index_epoch($self, $sync, $_) for (0..$epoch_max);
	} elsif ($v == 1) {
		my $uv = $ibx->uidvalidity;
		my $lc = $self->{oidx}->eidx_meta("lc-v1:$ekey//$uv");
		prepare_stack($sync, $lc ? "$lc..HEAD" : 'HEAD');
	} else {
		warn "E: $ekey unsupported inbox version (v$v)\n";
		return;
	}
}

sub eidx_sync { # main entry point
	my ($self, $opt) = @_;
	$self->idx_init($opt); # acquire lock via V2Writable::_idx_init
	$self->{oidx}->rethread_prepare($opt);

	_sync_inbox($self, $opt, $_) for (@{$self->{ibx_list}});
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
	my (%old, @old, %new, @new);
	if (-e $alt) {
		open(my $fh, '<', $alt) or die "open $alt: $!";
		$mode = (stat($fh))[2] & 07777;
		while (<$fh>) {
			push @old, $_ if !$old{$_}++;
		}
	}
	for my $ibx (@{$self->{ibx_list}}) {
		my $line = $ibx->git->{git_dir} . "/objects\n";
		next if $old{$line};
		$new{$line} = 1;
		push @new, $line;
	}
	push @old, @new;
	PublicInbox::V2Writable::write_alternates($info_dir, $mode, \@old);
	$self->parallel_init($self->{indexlevel});
	$self->umask_prepare;
	$self->with_umask(\&PublicInbox::V2Writable::_idx_init, $self, $opt);
	$self->{oidx}->begin_lazy;
	$self->{oidx}->eidx_prep;
}

no warnings 'once';
*done = \&PublicInbox::V2Writable::done;
*umask_prepare = \&PublicInbox::InboxWritable::umask_prepare;
*with_umask = \&PublicInbox::InboxWritable::with_umask;
*parallel_init = \&PublicInbox::V2Writable::parallel_init;
*nproc_shards = \&PublicInbox::V2Writable::nproc_shards;
*sync_prepare = \&PublicInbox::V2Writable::sync_prepare;
*index_epoch = \&PublicInbox::V2Writable::index_epoch;

1;
