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
	if (my $all_vmd = $self->{all_vmd}) {
		@$vmd{keys %$all_vmd} = values %$all_vmd;
	}
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
	my $vmd = $self->{-import_kw} ? { kw => $kw } : undef;
	if ($self->{-mail_sync}) {
		if ($f =~ m!\A(.+?)/(?:new|cur)/([^/]+)\z!) { # ugh...
			$vmd->{sync_info} = [ "maildir:$1", \(my $n = $2) ];
		} else {
			warn "E: $f was not from a Maildir?\n";
		}
	}
	input_eml_cb($self, $eml, $vmd);
}

sub input_net_cb { # imap_each / nntp_each
	my ($url, $uid, $kw, $eml, $self) = @_;
	my $vmd = $self->{-import_kw} ? { kw => $kw } : undef;
	$vmd->{sync_info} = [ $url, $uid ] if $self->{-mail_sync};
	input_eml_cb($self, $eml, $vmd);
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
	my $vmd_mod = $self->vmd_mod_extract(\@inputs);
	return $lei->fail(join("\n", @{$vmd_mod->{err}})) if $vmd_mod->{err};
	$self->{all_vmd} = $vmd_mod if scalar keys %$vmd_mod;
	$self->prepare_inputs($lei, \@inputs) or return;
	$self->{-mail_sync} = $lei->{opt}->{'mail-sync'} // 1;

	$lei->ale; # initialize for workers to read
	my $j = $lei->{opt}->{jobs} // scalar(@{$self->{inputs}}) || 1;
	if (my $net = $lei->{net}) {
		# $j = $net->net_concurrency($j); TODO
		if ($lei->{opt}->{incremental} // 1) {
			$net->{incremental} = 1;
			$net->{-lms_ro} = $lei->_lei_store->search->lms // 0;
		}
	} else {
		my $nproc = $self->detect_nproc;
		$j = $nproc if $j > $nproc;
	}
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{-wq_nr_workers} = $j // 1; # locked
	$lei->{-eml_noisy} = 1;
	(my $op_c, $ops) = $lei->workers_start($self, 'lei-import', $j, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_complete($self) unless $lei->{auth};
	$op_c->op_wait_event($ops);
}

sub _complete_import {
	my ($lei, @argv) = @_;
	my $sto = $lei->_lei_store or return;
	my $lms = $sto->search->lms or return;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	map { $match_cb->($_) } $lms->folders;
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;

# the following works even when LeiAuth is lazy-loaded
*net_merge_all = \&PublicInbox::LeiAuth::net_merge_all;
1;
