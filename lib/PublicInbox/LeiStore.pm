# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Local storage (cache/memo) for lei(1), suitable for personal/private
# mail iff on encrypted device/FS.  Based on v2, but only deduplicates
# git storage based on git OID (index deduplication is done in ContentHash)
#
# for xref3, the following are constant: $eidx_key = '.', $xnum = -1
#
# We rely on the synchronous IPC API for this in lei-daemon and
# multiple lei clients to write to it at once.  This allows the
# lei/store IPC process to be decoupled from network latency in
# lei WQ workers.
package PublicInbox::LeiStore;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock PublicInbox::IPC);
use PublicInbox::ExtSearchIdx;
use PublicInbox::Eml;
use PublicInbox::Import;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::V2Writable;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::MID qw(mids);
use PublicInbox::LeiSearch;
use PublicInbox::MDA;
use PublicInbox::Spawn qw(spawn);
use PublicInbox::MdirReader;
use PublicInbox::LeiToMail;
use File::Temp ();
use POSIX ();
use IO::Handle (); # ->autoflush
use Sys::Syslog qw(syslog openlog);
use Errno qw(EEXIST ENOENT);

sub new {
	my (undef, $dir, $opt) = @_;
	my $eidx = PublicInbox::ExtSearchIdx->new($dir, $opt);
	my $self = bless { priv_eidx => $eidx }, __PACKAGE__;
	eidx_init($self)->done if $opt->{creat};
	$self;
}

sub git { $_[0]->{priv_eidx}->git } # read-only

sub packing_factor { $PublicInbox::V2Writable::PACKING_FACTOR }

sub rotate_bytes {
	$_[0]->{rotate_bytes} // ((1024 * 1024 * 1024) / $_[0]->packing_factor)
}

sub git_ident ($) {
	my ($git) = @_;
	my $rdr = {};
	open $rdr->{2}, '>', '/dev/null' or die "open /dev/null: $!";
	chomp(my $i = $git->qx([qw(var GIT_COMMITTER_IDENT)], undef, $rdr));
	$i =~ /\A(.+) <([^>]+)> [0-9]+ [-\+]?[0-9]+$/ and return ($1, $2);
	my ($user, undef, undef, undef, undef, undef, $gecos) = getpwuid($<);
	($user) = (($user // $ENV{USER} // '') =~ /([\w\-\.\+]+)/);
	$user //= 'lei-user';
	($gecos) = (($gecos // '') =~ /([\w\-\.\+ \t]+)/);
	$gecos //= 'lei user';
	require Sys::Hostname;
	my ($host) = (Sys::Hostname::hostname() =~ /([\w\-\.]+)/);
	$host //= 'localhost';
	($gecos, "$user\@$host")
}

sub importer {
	my ($self) = @_;
	my $max;
	my $im = $self->{im};
	if ($im) {
		return $im if $im->{bytes_added} < $self->rotate_bytes;

		delete $self->{im};
		$im->done;
		undef $im;
		$self->checkpoint;
		$max = $self->{priv_eidx}->{mg}->git_epochs + 1;
	}
	my (undef, $tl) = eidx_init($self); # acquire lock
	$max //= $self->{priv_eidx}->{mg}->git_epochs;
	while (1) {
		my $latest = $self->{priv_eidx}->{mg}->add_epoch($max);
		my $git = PublicInbox::Git->new($latest);
		$self->done; # unlock
		# re-acquire lock, update alternates for new epoch
		(undef, $tl) = eidx_init($self);
		my $packed_bytes = $git->packed_bytes;
		my $unpacked_bytes = $packed_bytes / $self->packing_factor;
		if ($unpacked_bytes >= $self->rotate_bytes) {
			$max++;
			next;
		}
		my ($n, $e) = git_ident($git);
		$self->{im} = $im = PublicInbox::Import->new($git, $n, $e);
		$im->{bytes_added} = int($packed_bytes / $self->packing_factor);
		$im->{lock_path} = undef;
		$im->{path_type} = 'v2';
		return $im;
	}
}

sub search {
	PublicInbox::LeiSearch->new($_[0]->{priv_eidx}->{topdir});
}

# follows the stderr file
sub _tail_err {
	my ($self) = @_;
	print { $self->{-err_wr} } readline($self->{-tmp_err});
}

sub eidx_init {
	my ($self) = @_;
	my $eidx = $self->{priv_eidx};
	my $tl = wantarray && $self->{-err_wr} ?
			PublicInbox::OnDestroy->new($$, \&_tail_err, $self) :
			undef;
	$eidx->idx_init({-private => 1}); # acquires lock
	wantarray ? ($eidx, $tl) : $eidx;
}

sub _docids_for ($$) {
	my ($self, $eml) = @_;
	my %docids;
	my $eidx = $self->{priv_eidx};
	my ($chash, $mids) = PublicInbox::LeiSearch::content_key($eml);
	my $oidx = $eidx->{oidx};
	my $im = $self->{im};
	for my $mid (@$mids) {
		my ($id, $prev);
		while (my $cur = $oidx->next_by_mid($mid, \$id, \$prev)) {
			next if $cur->{bytes} == 0; # external-only message
			my $oid = $cur->{blob};
			my $docid = $cur->{num};
			my $bref = $im ? $im->cat_blob($oid) : undef;
			$bref //= $eidx->git->cat_file($oid) //
				_lms_rw($self)->local_blob($oid, 1) // do {
				warn "W: $oid (#$docid) <$mid> not found\n";
				next;
			};
			local $self->{current_info} = $oid;
			my $x = PublicInbox::Eml->new($bref);
			$docids{$docid} = $docid if content_hash($x) eq $chash;
		}
	}
	sort { $a <=> $b } values %docids;
}

# n.b. similar to LeiExportKw->export_kw_md, but this is for a single eml
sub export1_kw_md ($$$$$) {
	my ($self, $mdir, $bn, $oidbin, $vmdish) = @_; # vmd/vmd_mod
	my $orig = $bn;
	my (@try, $unkn, $kw);
	if ($bn =~ s/:2,([a-zA-Z]*)\z//) {
		($kw, $unkn) = PublicInbox::MdirReader::flags2kw($1);
		if (my $set = $vmdish->{kw}) {
			$kw = $set;
		} elsif (my $add = $vmdish->{'+kw'}) {
			@$kw{@$add} = ();
		} elsif (my $del = $vmdish->{-kw}) {
			delete @$kw{@$del};
		} # else no changes...
		@try = qw(cur new);
	} else { # no keywords, yet, could be in new/
		@try = qw(new cur);
		$unkn = [];
		if (my $set = $vmdish->{kw}) {
			$kw = $set;
		} elsif (my $add = $vmdish->{'+kw'}) {
			@$kw{@$add} = (); # auto-vivify
		} else { # ignore $vmdish->{-kw}
			$kw = [];
		}
	}
	$kw = [ keys %$kw ] if ref($kw) eq 'HASH';
	$bn .= ':2,'. PublicInbox::LeiToMail::kw2suffix($kw, @$unkn);
	return if $orig eq $bn; # no change

	# we use link(2) + unlink(2) since rename(2) may
	# inadvertently clobber if the "uniquefilename" part wasn't
	# actually unique.
	my $dst = "$mdir/cur/$bn";
	for my $d (@try) {
		my $src = "$mdir/$d/$orig";
		if (link($src, $dst)) {
			if (!unlink($src) and $! != ENOENT) {
				syslog('warning', "unlink($src): $!");
			}
			# TODO: verify oidbin?
			$self->{lms}->mv_src("maildir:$mdir",
					$oidbin, \$orig, $bn);
			return;
		} elsif ($! == EEXIST) { # lost race with "lei export-kw"?
			return;
		} elsif ($! != ENOENT) {
			syslog('warning', "link($src -> $dst): $!");
		}
	}
	for (@try) { return if -e "$mdir/$_/$orig" };
	$self->{lms}->clear_src("maildir:$mdir", \$orig);
}

sub sto_export_kw ($$$) {
	my ($self, $docid, $vmdish) = @_; # vmdish (vmd or vmd_mod)
	my ($eidx, $tl) = eidx_init($self);
	my $lms = _lms_rw($self) // return;
	my $xr3 = $eidx->{oidx}->get_xref3($docid, 1);
	for my $row (@$xr3) {
		my (undef, undef, $oidbin) = @$row;
		my $locs = $lms->locations_for($oidbin) // next;
		while (my ($loc, $ids) = each %$locs) {
			if ($loc =~ s!\Amaildir:!!i) {
				for my $id (@$ids) {
					export1_kw_md($self, $loc, $id,
							$oidbin, $vmdish);
				}
			}
			# TODO: IMAP
		}
	}
}

# vmd = { kw => [ qw(seen ...) ], L => [ qw(inbox ...) ] }
sub set_eml_vmd {
	my ($self, $eml, $vmd, $docids) = @_;
	my ($eidx, $tl) = eidx_init($self);
	$docids //= [ _docids_for($self, $eml) ];
	for my $docid (@$docids) {
		$eidx->idx_shard($docid)->ipc_do('set_vmd', $docid, $vmd);
		sto_export_kw($self, $docid, $vmd);
	}
	$docids;
}

sub add_eml_vmd {
	my ($self, $eml, $vmd) = @_;
	my ($eidx, $tl) = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->ipc_do('add_vmd', $docid, $vmd);
	}
	\@docids;
}

sub remove_eml_vmd { # remove just the VMD
	my ($self, $eml, $vmd) = @_;
	my ($eidx, $tl) = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->ipc_do('remove_vmd', $docid, $vmd);
	}
	\@docids;
}

sub _lms_rw ($) { # it is important to have eidx processes open before lms
	my ($self) = @_;
	my ($eidx, $tl) = eidx_init($self);
	$self->{lms} //= do {
		require PublicInbox::LeiMailSync;
		my $f = "$self->{priv_eidx}->{topdir}/mail_sync.sqlite3";
		my $lms = PublicInbox::LeiMailSync->new($f);
		$lms->lms_write_prepare;
		$lms;
	};
}

sub set_sync_info {
	my ($self, $oidhex, $folder, $id) = @_;
	_lms_rw($self)->set_src(pack('H*', $oidhex), $folder, $id);
}

sub _remove_if_local { # git->cat_async arg
	my ($bref, $oidhex, $type, $size, $self) = @_;
	$self->{im}->remove($bref) if $bref;
}

sub remove_docids ($;@) {
	my ($self, @docids) = @_;
	my $eidx = eidx_init($self);
	for my $docid (@docids) {
		$eidx->remove_doc($docid);
		$eidx->{oidx}->{dbh}->do(<<EOF, undef, $docid);
DELETE FROM xref3 WHERE docid = ?
EOF
	}
}

# remove the entire message from the index, does not touch mail_sync.sqlite3
sub remove_eml {
	my ($self, $eml) = @_;
	my $im = $self->importer; # may create new epoch
	my ($eidx, $tl) = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my @docids = _docids_for($self, $eml);
	my $git = $eidx->git;
	for my $docid (@docids) {
		my $xr3 = $oidx->get_xref3($docid, 1);
		for my $row (@$xr3) {
			my (undef, undef, $oidbin) = @$row;
			my $oidhex = unpack('H*', $oidbin);
			$git->cat_async($oidhex, \&_remove_if_local, $self);
		}
	}
	$git->async_wait_all;
	remove_docids($self, @docids);
	\@docids;
}

sub oid2docid ($$) {
	my ($self, $oid) = @_;
	my $eidx = eidx_init($self);
	my ($docid, @cull) = $eidx->{oidx}->blob_exists($oid);
	if (@cull) { # fixup old bugs...
		warn <<EOF;
W: $oid indexed as multiple docids: $docid @cull, culling to fixup old bugs
EOF
		remove_docids($self, @cull);
	}
	$docid;
}

sub _add_vmd ($$$$) {
	my ($self, $idx, $docid, $vmd) = @_;
	$idx->ipc_do('add_vmd', $docid, $vmd);
	sto_export_kw($self, $docid, $vmd);
}

sub _docids_and_maybe_kw ($$) {
	my ($self, $docids) = @_;
	return $docids unless wantarray;
	my $kw = {};
	for my $num (@$docids) { # likely only 1, unless ContentHash changes
		# can't use ->search->msg_keywords on uncommitted docs
		my $idx = $self->{priv_eidx}->idx_shard($num);
		my $tmp = eval { $idx->ipc_do('get_terms', 'K', $num) };
		if ($@) { warn "#$num get_terms: $@" }
		else { @$kw{keys %$tmp} = values(%$tmp) };
	}
	($docids, [ sort keys %$kw ]);
}

sub add_eml {
	my ($self, $eml, $vmd, $xoids) = @_;
	my $im = $self->{-fake_im} // $self->importer; # may create new epoch
	my ($eidx, $tl) = eidx_init($self);
	my $oidx = $eidx->{oidx}; # PublicInbox::Import::add checks this
	my $smsg = bless { -oidx => $oidx }, 'PublicInbox::Smsg';
	$smsg->{-eidx_git} = $eidx->git if !$self->{-fake_im};
	my $im_mark = $im->add($eml, undef, $smsg);
	if ($vmd && $vmd->{sync_info}) {
		set_sync_info($self, $smsg->{blob}, @{$vmd->{sync_info}});
	}
	unless ($im_mark) { # duplicate blob returns undef
		return unless wantarray;
		my @docids = $oidx->blob_exists($smsg->{blob});
		return _docids_and_maybe_kw $self, \@docids;
	}

	local $self->{current_info} = $smsg->{blob};
	my $vivify_xvmd = delete($smsg->{-vivify_xvmd}) // []; # exact matches
	if ($xoids) { # fuzzy matches from externals in ale->xoids_for
		delete $xoids->{$smsg->{blob}}; # added later
		if (scalar keys %$xoids) {
			my %docids = map { $_ => 1 } @$vivify_xvmd;
			for my $oid (keys %$xoids) {
				my $docid = oid2docid($self, $oid);
				$docids{$docid} = $docid if defined($docid);
			}
			@$vivify_xvmd = sort { $a <=> $b } keys(%docids);
		}
	}
	if (@$vivify_xvmd) { # docids list
		$xoids //= {};
		$xoids->{$smsg->{blob}} = 1;
		for my $docid (@$vivify_xvmd) {
			my $cur = $oidx->get_art($docid);
			my $idx = $eidx->idx_shard($docid);
			if (!$cur || $cur->{bytes} == 0) { # really vivifying
				$smsg->{num} = $docid;
				$oidx->add_overview($eml, $smsg);
				$smsg->{-merge_vmd} = 1;
				$idx->index_eml($eml, $smsg);
			} else { # lse fuzzy hit off ale
				$idx->ipc_do('add_eidx_info', $docid, '.', $eml);
			}
			for my $oid (keys %$xoids) {
				$oidx->add_xref3($docid, -1, $oid, '.');
			}
			_add_vmd($self, $idx, $docid, $vmd) if $vmd;
		}
		_docids_and_maybe_kw $self, $vivify_xvmd;
	} elsif (my @docids = _docids_for($self, $eml)) {
		# fuzzy match from within lei/store
		for my $docid (@docids) {
			my $idx = $eidx->idx_shard($docid);
			$oidx->add_xref3($docid, -1, $smsg->{blob}, '.');
			# add_eidx_info for List-Id
			$idx->ipc_do('add_eidx_info', $docid, '.', $eml);
			_add_vmd($self, $idx, $docid, $vmd) if $vmd;
		}
		_docids_and_maybe_kw $self, \@docids;
	} else { # totally new message, no keywords
		delete $smsg->{-oidx}; # for IPC-friendliness
		$smsg->{num} = $oidx->adj_counter('eidx_docid', '+');
		$oidx->add_overview($eml, $smsg);
		$oidx->add_xref3($smsg->{num}, -1, $smsg->{blob}, '.');
		my $idx = $eidx->idx_shard($smsg->{num});
		$idx->index_eml($eml, $smsg);
		_add_vmd($self, $idx, $smsg->{num}, $vmd) if $vmd;
		wantarray ? ($smsg, []) : $smsg;
	}
}

sub set_eml {
	my ($self, $eml, $vmd, $xoids) = @_;
	add_eml($self, $eml, $vmd, $xoids) //
		set_eml_vmd($self, $eml, $vmd);
}

sub index_eml_only {
	my ($self, $eml, $vmd, $xoids) = @_;
	require PublicInbox::FakeImport;
	local $self->{-fake_im} = PublicInbox::FakeImport->new;
	set_eml($self, $eml, $vmd, $xoids);
}

# store {kw} / {L} info for a message which is only in an external
sub _external_only ($$$) {
	my ($self, $xoids, $eml) = @_;
	my $eidx = $self->{priv_eidx};
	my $oidx = $eidx->{oidx} // die 'BUG: {oidx} missing';
	my $smsg = bless { blob => '' }, 'PublicInbox::Smsg';
	$smsg->{num} = $oidx->adj_counter('eidx_docid', '+');
	# save space for an externals-only message
	my $hdr = $eml->header_obj;
	$smsg->populate($hdr); # sets lines == 0
	$smsg->{bytes} = 0;
	delete @$smsg{qw(From Subject)};
	$smsg->{to} = $smsg->{cc} = $smsg->{from} = '';
	$oidx->add_overview($hdr, $smsg); # subject+references for threading
	$smsg->{subject} = '';
	for my $oid (keys %$xoids) {
		$oidx->add_xref3($smsg->{num}, -1, $oid, '.');
	}
	my $idx = $eidx->idx_shard($smsg->{num});
	$idx->index_eml(PublicInbox::Eml->new("\n\n"), $smsg);
	($smsg, $idx);
}

sub update_xvmd {
	my ($self, $xoids, $eml, $vmd_mod) = @_;
	my ($eidx, $tl) = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my %seen;
	for my $oid (keys %$xoids) {
		my $docid = oid2docid($self, $oid) // next;
		delete $xoids->{$oid};
		next if $seen{$docid}++;
		my $idx = $eidx->idx_shard($docid);
		$idx->ipc_do('update_vmd', $docid, $vmd_mod);
		sto_export_kw($self, $docid, $vmd_mod);
	}
	return unless scalar(keys(%$xoids));

	# see if it was indexed, but with different OID(s)
	if (my @docids = _docids_for($self, $eml)) {
		for my $docid (@docids) {
			next if $seen{$docid};
			for my $oid (keys %$xoids) {
				$oidx->add_xref3($docid, -1, $oid, '.');
			}
			my $idx = $eidx->idx_shard($docid);
			$idx->ipc_do('update_vmd', $docid, $vmd_mod);
			sto_export_kw($self, $docid, $vmd_mod);
		}
		return;
	}
	# totally unseen
	my ($smsg, $idx) = _external_only($self, $xoids, $eml);
	$idx->ipc_do('update_vmd', $smsg->{num}, $vmd_mod);
	sto_export_kw($self, $smsg->{num}, $vmd_mod);
}

# set or update keywords for external message, called via ipc_do
sub set_xvmd {
	my ($self, $xoids, $eml, $vmd) = @_;

	my ($eidx, $tl) = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my %seen;

	# see if we can just update existing docs
	for my $oid (keys %$xoids) {
		my $docid = oid2docid($self, $oid) // next;
		delete $xoids->{$oid}; # all done with this oid
		next if $seen{$docid}++;
		my $idx = $eidx->idx_shard($docid);
		$idx->ipc_do('set_vmd', $docid, $vmd);
		sto_export_kw($self, $docid, $vmd);
	}
	return unless scalar(keys(%$xoids));

	# n.b. we don't do _docids_for here, we expect the caller
	# already checked $lse->kw_changed before calling this sub

	return unless (@{$vmd->{kw} // []}) || (@{$vmd->{L} // []});
	# totally unseen:
	my ($smsg, $idx) = _external_only($self, $xoids, $eml);
	$idx->ipc_do('add_vmd', $smsg->{num}, $vmd);
	sto_export_kw($self, $smsg->{num}, $vmd);
}

sub checkpoint {
	my ($self, $wait) = @_;
	if (my $im = $self->{im}) {
		$wait ? $im->barrier : $im->checkpoint;
	}
	delete $self->{lms};
	$self->{priv_eidx}->checkpoint($wait);
}

sub xchg_stderr {
	my ($self) = @_;
	_tail_err($self) if $self->{-err_wr};
	my $dir = $self->{priv_eidx}->{topdir};
	return unless -e $dir;
	my $old = delete $self->{-tmp_err};
	my $pfx = POSIX::strftime('%Y%m%d%H%M%S', gmtime(time));
	my $err = File::Temp->new(TEMPLATE => "$pfx.$$.err-XXXX",
				SUFFIX => '.err', DIR => $dir);
	open STDERR, '>>', $err->filename or die "dup2: $!";
	STDERR->autoflush(1); # shared with shard subprocesses
	$self->{-tmp_err} = $err; # separate file description for RO access
	undef;
}

sub done {
	my ($self, $sock_ref) = @_;
	my $err = '';
	if (my $im = delete($self->{im})) {
		eval { $im->done };
		if ($@) {
			$err .= "import done: $@\n";
			warn $err;
		}
	}
	delete $self->{lms};
	$self->{priv_eidx}->done; # V2Writable::done
	xchg_stderr($self);
	die $err if $err;
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child(1) if $lei;
	xchg_stderr($self);
	if (my $to_close = delete($self->{to_close})) {
		close($_) for @$to_close;
	}
	openlog('lei/store', 'pid,nowait,nofatal,ndelay', 'user');
	$self->SUPER::ipc_atfork_child;
}

sub recv_and_run {
	my ($self, @args) = @_;
	local $PublicInbox::DS::in_loop = 0; # waitpid synchronously
	$self->SUPER::recv_and_run(@args);
}

sub write_prepare {
	my ($self, $lei) = @_;
	$lei // die 'BUG: $lei not passed';
	unless ($self->{-ipc_req}) {
		my $dir = $lei->store_path;
		substr($dir, -length('/lei/store'), 10, '');
		pipe(my ($r, $w)) or die "pipe: $!";
		$w->autoflush(1);
		# Mail we import into lei are private, so headers filtered out
		# by -mda for public mail are not appropriate
		local @PublicInbox::MDA::BAD_HEADERS = ();
		$self->wq_workers_start("lei/store $dir", 1, $lei->oldset, {
					lei => $lei,
					-err_wr => $w,
					to_close => [ $r ],
				});
		$self->wq_wait_async; # outlives $lei
		require PublicInbox::LeiStoreErr;
		PublicInbox::LeiStoreErr->new($r, $lei);
	}
	$lei->{sto} = $self;
}

1;
