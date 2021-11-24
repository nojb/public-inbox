# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Internal interface for a single Xapian shard in V2 inboxes.
# See L<public-inbox-v2-format(5)> for more info on how we shard Xapian
package PublicInbox::SearchIdxShard;
use strict;
use v5.10.1;
use parent qw(PublicInbox::SearchIdx PublicInbox::IPC);
use PublicInbox::OnDestroy;

sub new {
	my ($class, $v2w, $shard) = @_; # v2w may be ExtSearchIdx
	my $ibx = $v2w->{ibx};
	my $self = $ibx ? $class->SUPER::new($ibx, 1, $shard)
			: $class->eidx_shard_new($v2w, $shard);
	# create the DB before forking:
	$self->idx_acquire;
	$self->set_metadata_once;
	$self->idx_release;
	if ($v2w->{parallel}) {
		local $self->{-v2w_afc} = $v2w;
		$self->ipc_worker_spawn("shard[$shard]");
		# F_SETPIPE_SZ = 1031 on Linux; increasing the pipe size for
		# inputs speeds V2Writable batch imports across 8 cores by
		# nearly 20%.  Since any of our responses are small, make
		# the response pipe as small as possible
		if ($^O eq 'linux') {
			fcntl($self->{-ipc_req}, 1031, 1048576);
			fcntl($self->{-ipc_res}, 1031, 4096);
		}
	}
	$self;
}

sub _worker_done {
	my ($self) = @_;
	if ($self->need_xapian) {
		die "$$ $0 xdb not released\n" if $self->{xdb};
	}
	die "$$ $0 still in transaction\n" if $self->{txn};
}

sub ipc_atfork_child { # called automatically before ipc_worker_loop
	my ($self) = @_;
	my $v2w = delete $self->{-v2w_afc} or die 'BUG: {-v2w_afc} missing';
	$v2w->atfork_child; # calls ipc_sibling_atfork_child on our siblings
	$v2w->{current_info} = "[$self->{shard}]"; # for $SIG{__WARN__}
	$self->begin_txn_lazy;
	# caller must capture this:
	PublicInbox::OnDestroy->new($$, \&_worker_done, $self);
}

sub index_eml {
	my ($self, $eml, $smsg, $eidx_key) = @_;
	$smsg->{eidx_key} = $eidx_key if defined $eidx_key;
	$self->ipc_do('add_xapian', $eml, $smsg);
}

# wait for return to determine when ipc_do('commit_txn_lazy') is done
sub echo {
	shift;
	"@_";
}

sub idx_close {
	my ($self) = @_;
	die "transaction in progress $self\n" if $self->{txn};
	$self->idx_release if $self->{xdb};
}

sub shard_close {
	my ($self) = @_;
	$self->ipc_do('idx_close');
	$self->ipc_worker_stop;
}

1;
