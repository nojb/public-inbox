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
	$v2w->atfork_child; # calls shard_atfork_child on our siblings
	$v2w->{current_info} = "[$self->{shard}]"; # for $SIG{__WARN__}
	$self->begin_txn_lazy;
	# caller must capture this:
	PublicInbox::OnDestroy->new($$, \&_worker_done, $self);
}

sub index_eml {
	my ($self, $eml, $smsg, $eidx_key) = @_;
	$smsg->{eidx_key} = $eidx_key if defined $eidx_key;
	$self->ipc_do('add_message', $eml, $smsg);
}

# needed when there's multiple IPC workers and the parent forking
# causes newer siblings to inherit older siblings sockets
sub shard_atfork_child {
	my ($self) = @_;
	my $pid = delete($self->{-ipc_worker_pid}) or
			die "BUG: $$ no -ipc_worker_pid";
	my $s1 = delete($self->{-ipc_sock}) or die "BUG: $$ no -ipc_sock";
	$pid == $$ and die "BUG: $$ shard_atfork_child called on itself";
	close($s1) or die "close -ipc_sock: $!";
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

sub shard_over_check {
	my ($self, $over) = @_;
	if ($self->{-ipc_sock} && $over->{dbh}) {
		# can't send DB handles over IPC
		$over = ref($over)->new($over->{dbh}->sqlite_db_filename);
	}
	$self->ipc_do('over_check', $over);
}

1;
