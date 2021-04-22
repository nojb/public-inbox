# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei import" sub-command
package PublicInbox::LeiImport;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);

# /^input_/ subs are used by (or override) PublicInbox::LeiInput superclass

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml, $vmd) = @_;
	my $xoids = $self->{lei}->{ale}->xoids_for($eml);
	$self->{lei}->{sto}->ipc_do('set_eml', $eml, $vmd, $xoids);
}

sub input_mbox_cb { # MboxReader callback
	my ($eml, $self) = @_;
	my $vmd;
	if ($self->{-import_kw}) {
		my $kw = PublicInbox::MboxReader::mbox_keywords($eml);
		$vmd = { kw => $kw } if scalar(@$kw);
	}
	input_eml_cb($self, $eml, $vmd);
}

sub input_maildir_cb { # maildir_each_eml cb
	my ($f, $kw, $eml, $self) = @_;
	input_eml_cb($self, $eml, $self->{-import_kw} ? { kw => $kw } : undef);
}

sub input_net_cb { # imap_each, nntp_each cb
	my ($url, $uid, $kw, $eml, $self) = @_;
	input_eml_cb($self, $eml, $self->{-import_kw} ? { kw => $kw } : undef);
}

sub import_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $imp = delete $lei->{imp} // return $lei->fail('BUG: {imp} gone');
	$imp->wq_wait_old($lei->can('wq_done_wait'), $lei, 'non-fatal');
}

sub net_merge_complete { # callback used by LeiAuth
	my ($self) = @_;
	$self->wq_io_do('process_inputs');
	$self->wq_close(1);
}

sub lei_import { # the main "lei import" method
	my ($lei, @inputs) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	my $self = bless {}, __PACKAGE__;
	$self->{-import_kw} = $lei->{opt}->{kw} // 1;
	$self->prepare_inputs($lei, \@inputs) or return;
	$lei->ale; # initialize for workers to read
	my $j = $lei->{opt}->{jobs} // scalar(@{$self->{inputs}}) || 1;
	if (my $net = $lei->{net}) {
		# $j = $net->net_concurrency($j); TODO
		if ($lei->{opt}->{incremental} // 1) {
			$net->{incremental} = 1;
			$net->{itrk_fn} = $lei->store_path .
						'/net_last.sqlite3';
		}
	} else {
		my $nproc = $self->detect_nproc;
		$j = $nproc if $j > $nproc;
	}
	my $ops = { '' => [ \&import_done, $lei ] };
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{-wq_nr_workers} = $j // 1; # locked
	(my $op_c, $ops) = $lei->workers_start($self, 'lei_import', $j, $ops);
	$lei->{imp} = $self;
	net_merge_complete($self) unless $lei->{auth};
	$op_c->op_wait_event($ops);
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;

# the following works even when LeiAuth is lazy-loaded
*net_merge_all = \&PublicInbox::LeiAuth::net_merge_all;
1;
