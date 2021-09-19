# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# WQ worker for dealing with LeiImport IMAP flags on already-imported messages
# WQ key: {ikw}
package PublicInbox::LeiImportKw;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);

sub new {
	my ($cls, $lei) = @_;
	my $self = bless { -wq_ident => 'lei import_kw worker' }, $cls;
	my $j = $self->detect_nproc // 4;
	$j = 4 if $j > 4;
	my ($op_c, $ops) = $lei->workers_start($self, $j);
	$op_c->{ops} = $ops; # for PktOp->event_step
	$self->{lei_sock} = $lei->{sock};
	$lei->{ikw} = $self;
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child;
	my $net = delete $lei->{net} // die 'BUG: no lei->{net}';
	$self->{sto} = $lei->{sto} // die 'BUG: no lei->{sto}';
	$self->{verbose} = $lei->{opt}->{verbose};
	$self->{lse} = $self->{sto}->search;
	$self->{over} = $self->{lse}->over;
	$self->{-lms_ro} = $net->{-lms_ro} || die 'BUG: net->{-lms_ro} FALSE';
	$self->SUPER::ipc_atfork_child;
}

sub ck_update_kw { # via wq_io_do
	my ($self, $url, $uid, $kw) = @_;
	my $oidbin = $self->{-lms_ro}->imap_oidbin($url, $uid) // return;
	my @docids = $self->{over}->oidbin_exists($oidbin) or return;
	$self->{lse}->kw_changed(undef, $kw, \@docids) or return;
	$self->{verbose} and
		$self->{lei}->qerr('# '.unpack('H*', $oidbin)." => @$kw\n");
	$self->{sto}->wq_do('set_eml_vmd', undef, { kw => $kw }, \@docids);
}

sub ikw_done_wait {
	my ($arg, $pid) = @_;
	my ($self, $lei) = @$arg;
	$lei->can('wq_done_wait')->($arg, $pid);
}

sub _lei_wq_eof { # EOF callback for main lei daemon
	my ($lei) = @_;
	my $ikw = delete $lei->{ikw} or return $lei->fail;
	$lei->sto_done_request($ikw->{lei_sock});
	$ikw->wq_wait_old(\&ikw_done_wait, $lei);
}

1;
