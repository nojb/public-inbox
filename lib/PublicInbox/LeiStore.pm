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
use List::Util qw(max);
use File::Temp ();
use POSIX ();

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

sub git_pfx { "$_[0]->{priv_eidx}->{topdir}/local" };

sub git_epoch_max  {
	my ($self) = @_;
	if (opendir(my $dh, $self->git_pfx)) {
		max(map {
			substr($_, 0, -4) + 0; # drop ".git" suffix
		} grep(/\A[0-9]+\.git\z/, readdir($dh))) // 0;
	} else {
		$!{ENOENT} ? 0 : die("opendir ${\$self->git_pfx}: $!\n");
	}
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
		$max = $self->git_epoch_max + 1;
	}
	my $pfx = $self->git_pfx;
	$max //= $self->git_epoch_max;
	while (1) {
		my $latest = "$pfx/$max.git";
		my $old = -e $latest;
		PublicInbox::Import::init_bare($latest);
		my $git = PublicInbox::Git->new($latest);
		if (!$old) {
			$git->qx(qw(config core.sharedRepository 0600));
			$self->done; # force eidx_init on next round
		}
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
	$eidx->idx_init({-private => 1});
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
			$bref //= $eidx->git->cat_file($oid) // do {
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

sub set_eml_vmd {
	my ($self, $eml, $vmd, $docids) = @_;
	my ($eidx, $tl) = eidx_init($self);
	$docids //= [ _docids_for($self, $eml) ];
	for my $docid (@$docids) {
		$eidx->idx_shard($docid)->ipc_do('set_vmd', $docid, $vmd);
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

sub remove_eml_vmd {
	my ($self, $eml, $vmd) = @_;
	my ($eidx, $tl) = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->ipc_do('remove_vmd', $docid, $vmd);
	}
	\@docids;
}

sub add_eml {
	my ($self, $eml, $vmd, $xoids) = @_;
	my $im = $self->importer; # may create new epoch
	my ($eidx, $tl) = eidx_init($self); # updates/writes alternates file
	my $oidx = $eidx->{oidx}; # PublicInbox::Import::add checks this
	my $smsg = bless { -oidx => $oidx }, 'PublicInbox::Smsg';
	$im->add($eml, undef, $smsg) or return; # duplicate returns undef

	local $self->{current_info} = $smsg->{blob};
	my $vivify_xvmd = delete($smsg->{-vivify_xvmd}) // []; # exact matches
	if ($xoids) { # fuzzy matches from externals in ale->xoids_for
		delete $xoids->{$smsg->{blob}}; # added later
		if (scalar keys %$xoids) {
			my %docids = map { $_ => 1 } @$vivify_xvmd;
			for my $oid (keys %$xoids) {
				my @id = $oidx->blob_exists($oid);
				@docids{@id} = @id;
			}
			@$vivify_xvmd = sort { $a <=> $b } keys(%docids);
		}
	}
	if (@$vivify_xvmd) {
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
			$idx->ipc_do('add_vmd', $docid, $vmd) if $vmd;
		}
		$vivify_xvmd;
	} elsif (my @docids = _docids_for($self, $eml)) {
		# fuzzy match from within lei/store
		for my $docid (@docids) {
			my $idx = $eidx->idx_shard($docid);
			$oidx->add_xref3($docid, -1, $smsg->{blob}, '.');
			# add_eidx_info for List-Id
			$idx->ipc_do('add_eidx_info', $docid, '.', $eml);
			$idx->ipc_do('add_vmd', $docid, $vmd) if $vmd;
		}
		\@docids;
	} else { # totally new message
		$smsg->{num} = $oidx->adj_counter('eidx_docid', '+');
		$oidx->add_overview($eml, $smsg);
		$oidx->add_xref3($smsg->{num}, -1, $smsg->{blob}, '.');
		my $idx = $eidx->idx_shard($smsg->{num});
		$idx->index_eml($eml, $smsg);
		$idx->ipc_do('add_vmd', $smsg->{num}, $vmd) if $vmd;
		$smsg;
	}
}

sub set_eml {
	my ($self, $eml, $vmd, $xoids) = @_;
	add_eml($self, $eml, $vmd, $xoids) //
		set_eml_vmd($self, $eml, $vmd);
}

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
		my @docids = $oidx->blob_exists($oid) or next;
		scalar(@docids) > 1 and
			warn "W: $oid indexed as multiple docids: @docids\n";
		for my $docid (@docids) {
			next if $seen{$docid}++;
			my $idx = $eidx->idx_shard($docid);
			$idx->ipc_do('update_vmd', $docid, $vmd_mod);
		}
		delete $xoids->{$oid};
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
		}
		return;
	}
	# totally unseen
	my ($smsg, $idx) = _external_only($self, $xoids, $eml);
	$idx->ipc_do('update_vmd', $smsg->{num}, $vmd_mod);
}

# set or update keywords for external message, called via ipc_do
sub set_xvmd {
	my ($self, $xoids, $eml, $vmd) = @_;

	my ($eidx, $tl) = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my %seen;

	# see if we can just update existing docs
	for my $oid (keys %$xoids) {
		my @docids = $oidx->blob_exists($oid) or next;
		scalar(@docids) > 1 and
			warn "W: $oid indexed as multiple docids: @docids\n";
		for my $docid (@docids) {
			next if $seen{$docid}++;
			my $idx = $eidx->idx_shard($docid);
			$idx->ipc_do('set_vmd', $docid, $vmd);
		}
		delete $xoids->{$oid}; # all done with this oid
	}
	return unless scalar(keys(%$xoids));

	# n.b. we don't do _docids_for here, we expect the caller
	# already checked $lse->kw_changed before calling this sub

	return unless (@{$vmd->{kw} // []}) || (@{$vmd->{L} // []});
	# totally unseen:
	my ($smsg, $idx) = _external_only($self, $xoids, $eml);
	$idx->ipc_do('add_vmd', $smsg->{num}, $vmd);
}

sub checkpoint {
	my ($self, $wait) = @_;
	if (my $im = $self->{im}) {
		$wait ? $im->barrier : $im->checkpoint;
	}
	$self->{priv_eidx}->checkpoint($wait);
}

sub xchg_stderr {
	my ($self) = @_;
	_tail_err($self) if $self->{-err_wr};
	my $dir = $self->{priv_eidx}->{topdir};
	return unless -e $dir;
	my $old = delete $self->{-tmp_err};
	my $pfx = POSIX::strftime('%Y%m%d%H%M%S', gmtime(time));
	my $err = File::Temp->new(TEMPLATE => "$pfx.$$.lei_storeXXXX",
				SUFFIX => '.err', DIR => $dir);
	open STDERR, '>>', $err->filename or die "dup2: $!";
	STDERR->autoflush(1); # shared with shard subprocesses
	$self->{-tmp_err} = $err; # separate file description for RO access
	undef;
}

sub done {
	my ($self) = @_;
	my $err = '';
	if (my $im = delete($self->{im})) {
		eval { $im->done };
		if ($@) {
			$err .= "import done: $@\n";
			warn $err;
		}
	}
	$self->{priv_eidx}->done; # V2Writable::done
	xchg_stderr($self);
	die $err if $err;
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child(1) if $lei;
	xchg_stderr($self);
	if (my $err = delete($self->{err_pipe})) {
		close $err->[0];
		$self->{-err_wr} = $err->[1];
	}
	$SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$self->SUPER::ipc_atfork_child;
}

sub write_prepare {
	my ($self, $lei) = @_;
	unless ($self->{-ipc_req}) {
		my $d = $lei->store_path;
		$self->ipc_lock_init("$d/ipc.lock");
		substr($d, -length('/lei/store'), 10, '');
		my $err_pipe;
		unless ($lei->{oneshot}) {
			pipe(my ($r, $w)) or die "pipe: $!";
			$err_pipe = [ $r, $w ];
		}
		# Mail we import into lei are private, so headers filtered out
		# by -mda for public mail are not appropriate
		local @PublicInbox::MDA::BAD_HEADERS = ();
		$self->ipc_worker_spawn("lei/store $d", $lei->oldset,
					{ lei => $lei, err_pipe => $err_pipe });
		if ($err_pipe) {
			require PublicInbox::LeiStoreErr;
			PublicInbox::LeiStoreErr->new($err_pipe->[0], $lei);
		}
	}
	$lei->{sto} = $self;
}

1;
