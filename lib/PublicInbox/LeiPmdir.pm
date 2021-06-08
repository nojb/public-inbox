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
	my $jobs = $lei->{opt}->{jobs};
	$jobs =~ /\A[0-9]+,([0-9]+)\z/ and $jobs = $1;
	my $nproc = $jobs // do {
		# untested with >=4 CPUs, though I suspect I/O latency
		# of SATA SSD storage will make >=4 processes unnecessary,
		# here.  NVMe users may wish to use '-j'
		my $n = $self->detect_nproc;
		$n = 4 if $n > 4;
	};
	my ($op_c, $ops) = $lei->workers_start($self, $nproc,
		undef, { ipt => $ipt }); # LeiInput subclass
	$op_c->{ops} = $ops; # for PktOp->event_step
	$lei->{pmd} = $self;
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child;
	my $ipt = $self->{ipt} // die 'BUG: no self->{ipt}';
	$ipt->{lei} = $lei;
	$ipt->{sto} = $lei->{sto} // die 'BUG: no lei->{sto}';
	$ipt->{lse} = $ipt->{sto}->search;
	$ipt->{over} = $ipt->{lse}->over;
	$ipt->{-lms_ro} //= $ipt->{lse}->lms; # may be undef or '0'
	$self->SUPER::ipc_atfork_child;
}

sub each_mdir_fn { # maildir_each_file callback
	my ($f, $self, @args) = @_;
	$self->wq_io_do('mdir_iter', [], $f, @args);
}

sub mdir_iter { # via wq_io_do
	my ($self, $f, @args) = @_;
	$self->{ipt}->pmdir_cb($f, @args);
}

sub pmd_done_wait {
	my ($arg, $pid) = @_;
	my ($self, $lei) = @$arg;
	my $wait = $lei->{sto}->ipc_do('done');
	$lei->can('wq_done_wait')->($arg, $pid);
}

sub _lei_wq_eof { # EOF callback for main lei daemon
	my ($lei) = @_;
	my $pmd = delete $lei->{pmd} or return $lei->fail;
	$pmd->wq_wait_old(\&pmd_done_wait, $lei);
}

1;
