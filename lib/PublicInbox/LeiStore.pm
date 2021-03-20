# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Local storage (cache/memo) for lei(1), suitable for personal/private
# mail iff on encrypted device/FS.  Based on v2, but only deduplicates
# based on git OID.
#
# for xref3, the following are constant: $eidx_key = '.', $xnum = -1
package PublicInbox::LeiStore;
use strict;
use v5.10.1;
use parent qw(PublicInbox::Lock PublicInbox::IPC);
use PublicInbox::ExtSearchIdx;
use PublicInbox::Import;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::V2Writable;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::MID qw(mids);
use PublicInbox::LeiSearch;
use PublicInbox::MDA;
use List::Util qw(max);

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
	chomp(my $i = $git->qx(qw(var GIT_COMMITTER_IDENT)));
	warn "$git->{git_dir} GIT_COMMITTER_IDENT failed\n" if $?;
	$i =~ /\A(.+) <([^>]+)> [0-9]+ [-\+]?[0-9]+$/ ? ($1, $2) :
		('lei user', 'x@example.com')
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
		$git->qx(qw(config core.sharedRepository 0600)) if !$old;
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

sub eidx_init {
	my ($self) = @_;
	my $eidx = $self->{priv_eidx};
	$eidx->idx_init({-private => 1});
	$eidx;
}

sub _docids_for ($$) {
	my ($self, $eml) = @_;
	my %docids;
	my ($chash, $mids) = PublicInbox::LeiSearch::content_key($eml);
	my $eidx = eidx_init($self);
	my $oidx = $eidx->{oidx};
	my $im = $self->{im};
	for my $mid (@$mids) {
		my ($id, $prev);
		while (my $cur = $oidx->next_by_mid($mid, \$id, \$prev)) {
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
	my ($self, $eml, $vmd) = @_;
	my $eidx = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->ipc_do('set_vmd', $docid, $vmd);
	}
	\@docids;
}

sub add_eml_vmd {
	my ($self, $eml, $vmd) = @_;
	my $eidx = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->ipc_do('add_vmd', $docid, $vmd);
	}
	\@docids;
}

sub remove_eml_vmd {
	my ($self, $eml, $vmd) = @_;
	my $eidx = eidx_init($self);
	my @docids = _docids_for($self, $eml);
	for my $docid (@docids) {
		$eidx->idx_shard($docid)->ipc_do('remove_vmd', $docid, $vmd);
	}
	\@docids;
}

sub add_eml {
	my ($self, $eml, $vmd) = @_;
	my $im = $self->importer; # may create new epoch
	my $eidx = eidx_init($self); # writes ALL.git/objects/info/alternates
	my $oidx = $eidx->{oidx};
	my $smsg = bless { -oidx => $oidx }, 'PublicInbox::Smsg';
	$im->add($eml, undef, $smsg) or return; # duplicate returns undef

	local $self->{current_info} = $smsg->{blob};
	if (my @docids = _docids_for($self, $eml)) {
		for my $docid (@docids) {
			my $idx = $eidx->idx_shard($docid);
			$oidx->add_xref3($docid, -1, $smsg->{blob}, '.');
			# add_eidx_info for List-Id
			$idx->ipc_do('add_eidx_info', $docid, '.', $eml);
			$idx->ipc_do('add_vmd', $docid, $vmd) if $vmd;
		}
		\@docids;
	} else {
		$smsg->{num} = $oidx->adj_counter('eidx_docid', '+');
		$oidx->add_overview($eml, $smsg);
		$oidx->add_xref3($smsg->{num}, -1, $smsg->{blob}, '.');
		my $idx = $eidx->idx_shard($smsg->{num});
		$idx->index_eml($eml, $smsg);
		$idx->ipc_do('add_vmd', $smsg->{num}, $vmd ) if $vmd;
		$smsg;
	}
}

sub set_eml {
	my ($self, $eml, $vmd) = @_;
	add_eml($self, $eml, $vmd) // set_eml_vmd($self, $eml, $vmd);
}

sub add_eml_maybe {
	my ($self, $eml) = @_;
	my $lxs = $self->{lxs_all_local} // die 'BUG: no {lxs_all_local}';
	return if $lxs->xids_for($eml, 1);
	add_eml($self, $eml);
}

# set or update keywords for external message, called via ipc_do
sub set_xkw {
	my ($self, $eml, $kw) = @_;
	my $lxs = $self->{lxs_all_local} // die 'BUG: no {lxs_all_local}';
	if ($lxs->xids_for($eml, 1)) { # is it in a local external?
		# TODO: index keywords only
	} else {
		set_eml($self, $eml, { kw => $kw });
	}
}

sub checkpoint {
	my ($self, $wait) = @_;
	if (my $im = $self->{im}) {
		$wait ? $im->barrier : $im->checkpoint;
	}
	$self->{priv_eidx}->checkpoint($wait);
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
	$self->{priv_eidx}->done;
	die $err if $err;
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->lei_atfork_child(1) if $lei;
	$self->SUPER::ipc_atfork_child;
}

sub refresh_local_externals {
	my ($self) = @_;
	my $cfg = $self->{lei}->_lei_cfg or return;
	my $cur_cfg = $self->{cur_cfg} // -1;
	my $lxs = $self->{lxs_all_local};
	if ($cfg != $cur_cfg || !$lxs) {
		$lxs = PublicInbox::LeiXSearch->new;
		my @loc = $self->{lei}->externals_each;
		for my $loc (@loc) { # locals only
			$lxs->prepare_external($loc) if -d $loc;
		}
		$self->{lei}->ale->refresh_externals($lxs);
		$lxs->{git} = $self->{lei}->ale->git;
		$self->{lxs_all_local} = $lxs;
		$self->{cur_cfg} = $cfg;
	}
}

sub write_prepare {
	my ($self, $lei) = @_;
	unless ($self->{-ipc_req}) {
		require PublicInbox::LeiXSearch;
		$self->ipc_lock_init($lei->store_path . '/ipc.lock');
		# Mail we import into lei are private, so headers filtered out
		# by -mda for public mail are not appropriate
		local @PublicInbox::MDA::BAD_HEADERS = ();
		$self->ipc_worker_spawn('lei_store', $lei->oldset,
					{ lei => $lei });
	}
	my $wait = $self->ipc_do('refresh_local_externals');
	$lei->{sto} = $self;
}

1;
