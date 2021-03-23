# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei import" sub-command
package PublicInbox::LeiImport;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::Eml;
use PublicInbox::PktOp qw(pkt_do);

sub eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml, $vmd) = @_;
	my $xoids = $self->{lei}->{ale}->xoids_for($eml);
	$self->{lei}->{sto}->ipc_do('set_eml', $eml, $vmd, $xoids);
}

sub mbox_cb { # MboxReader callback used by PublicInbox::LeiInput::input_fh
	my ($eml, $self) = @_;
	my $vmd;
	if ($self->{-import_kw}) {
		my $kw = PublicInbox::MboxReader::mbox_keywords($eml);
		$vmd = { kw => $kw } if scalar(@$kw);
	}
	eml_cb($self, $eml, $vmd);
}

sub import_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($imp, $lei) = @$arg;
	$lei->child_error($?, 'non-fatal errors during import') if $?;
	my $sto = delete $lei->{sto};
	my $wait = $sto->ipc_do('done') if $sto; # PublicInbox::LeiStore::done
	$lei->dclose;
}

sub import_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $imp = delete $lei->{imp} or return;
	$imp->wq_wait_old(\&import_done_wait, $lei);
}

sub net_merge_complete { # callback used by LeiAuth
	my ($self) = @_;
	for my $input (@{$self->{inputs}}) {
		$self->wq_io_do('import_path_url', [], $input);
	}
	$self->wq_close(1);
}

sub import_start {
	my ($lei) = @_;
	my $self = $lei->{imp};
	$lei->ale; # initialize for workers to read
	my $j = $lei->{opt}->{jobs} // scalar(@{$self->{inputs}}) || 1;
	if (my $net = $lei->{net}) {
		# $j = $net->net_concurrency($j); TODO
	} else {
		my $nproc = $self->detect_nproc;
		$j = $nproc if $j > $nproc;
	}
	my $ops = { '' => [ \&import_done, $lei ] };
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{-wq_nr_workers} = $j // 1; # locked
	my $op = $lei->workers_start($self, 'lei_import', undef, $ops);
	$self->wq_io_do('import_stdin', []) if $self->{0};
	net_merge_complete($self) unless $lei->{auth};
	while ($op && $op->{sock}) { $op->event_step }
}

sub lei_import { # the main "lei import" method
	my ($lei, @inputs) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	my $self = $lei->{imp} = bless {}, __PACKAGE__;
	$self->{-import_kw} = $lei->{opt}->{kw} // 1;
	$self->prepare_inputs($lei, \@inputs) or return;
	import_start($lei);
}

sub _import_maildir { # maildir_each_eml cb
	my ($f, $kw, $eml, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml', $eml, $set_kw ? { kw => $kw }: ());
}

sub _import_net { # imap_each, nntp_each cb
	my ($url, $uid, $kw, $eml, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml', $eml, $set_kw ? { kw => $kw } : ());
}

sub import_path_url {
	my ($self, $input) = @_;
	my $lei = $self->{lei};
	my $ifmt = lc($lei->{opt}->{'in-format'} // '');
	# TODO auto-detect?
	if ($input =~ m!\Aimaps?://!i) {
		$lei->{net}->imap_each($input, \&_import_net, $lei->{sto},
					$self->{-import_kw});
		return;
	} elsif ($input =~ m!\A(?:nntps?|s?news)://!i) {
		$lei->{net}->nntp_each($input, \&_import_net, $lei->{sto}, 0);
		return;
	} elsif ($input =~ s!\A([a-z0-9]+):!!i) {
		$ifmt = lc $1;
	}
	if (-f $input) {
		my $m = $lei->{opt}->{'lock'} // ($ifmt eq 'eml' ? ['none'] :
				PublicInbox::MboxLock->defaults);
		my $mbl = PublicInbox::MboxLock->acq($input, 0, $m);
		$self->input_fh($ifmt, $mbl->{fh}, $input);
	} elsif (-d _ && (-d "$input/cur" || -d "$input/new")) {
		return $lei->fail(<<EOM) if $ifmt && $ifmt ne 'maildir';
$input appears to a be a maildir, not $ifmt
EOM
		PublicInbox::MdirReader::maildir_each_eml($input,
					\&_import_maildir,
					$lei->{sto}, $self->{-import_kw});
	} else {
		$lei->fail("$input unsupported (TODO)");
	}
}

sub import_stdin {
	my ($self) = @_;
	my $lei = $self->{lei};
	my $in = delete $self->{0};
	$self->input_fh($lei->{opt}->{'in-format'}, $in, '<stdin>');
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;

# the following works even when LeiAuth is lazy-loaded
*net_merge_all = \&PublicInbox::LeiAuth::net_merge_all;
1;
