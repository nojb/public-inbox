# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# WQ worker for dealing with parallel Maildir reads;
# this does NOT use the {shard_info} field of LeiToMail
# (and we may remove {shard_info})
# WQ key: {pmd}
package PublicInbox::LeiPmdir;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);

sub new {
	my ($cls, $lei, $ipt) = @_;
	my $self = bless { -wq_ident => 'lei Maildir worker' }, $cls;
	my $jobs = $lei->{opt}->{jobs} // '';
	$jobs =~ /\A[0-9]+,([0-9]+)\z/ and $jobs = $1;
	my $nproc = $jobs || do {
		# barely tested with >=4 CPUs, though I suspect I/O latency
		# of SATA SSD storage will make >=4 processes unnecessary,
		# here.  NVMe users may wish to use '-j'
		my $n = $self->detect_nproc;
		$n = $n > 4 ? 4 : $n;
	};
	my ($op_c, $ops) = $lei->workers_start($self, $nproc,
		undef, { ipt => $ipt }); # LeiInput subclass
	$op_c->{ops} = $ops; # for PktOp->event_step
	$self->{lei_sock} = $lei->{sock}; # keep client for pmd_done_wait
	$lei->{pmd} = $self;
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $ipt = $self->{ipt} // die 'BUG: no self->{ipt}';
	my $lei = $ipt->{lei} = $self->{lei};
	delete @$lei{qw(auth net)}; # no network access in this worker
	$ipt->ipc_atfork_child; # calls _lei_atfork_child;
}

sub each_mdir_fn { # maildir_each_file callback
	my ($f, $fl, $self, @args) = @_;
	$self->wq_io_do('mdir_iter', [], $f, $fl, @args);
}

sub mdir_iter { # via wq_io_do
	my ($self, $f, $fl, @args) = @_;
	$self->{ipt}->pmdir_cb($f, $fl, @args);
}

sub _lei_wq_eof { # EOF callback for main lei daemon
	my ($lei) = @_;
	my $pmd = delete $lei->{pmd} or return $lei->fail;
	$lei->sto_done_request($pmd->{lei_sock});
	$pmd->wq_wait_old($lei->can('wq_done_wait'), $lei);
}

1;
