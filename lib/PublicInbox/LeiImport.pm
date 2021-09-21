# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei import" sub-command
package PublicInbox::LeiImport;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::InboxWritable qw(eml_from_path);

# /^input_/ subs are used by (or override) PublicInbox::LeiInput superclass

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml, $vmd) = @_;
	my $xoids = $self->{lei}->{ale}->xoids_for($eml);
	if (my $all_vmd = $self->{all_vmd}) {
		@$vmd{keys %$all_vmd} = values %$all_vmd;
	}
	$self->{lei}->{sto}->wq_do('set_eml', $eml, $vmd, $xoids);
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

sub pmdir_cb { # called via wq_io_do from LeiPmdir->each_mdir_fn
	my ($self, $f, $fl) = @_;
	my ($folder, $bn) = ($f =~ m!\A(.+?)/(?:new|cur)/([^/]+)\z!) or
		die "BUG: $f was not from a Maildir?\n";
	my $kw = PublicInbox::MdirReader::flags2kw($fl);
	substr($folder, 0, 0) = 'maildir:'; # add prefix
	my $lse = $self->{lse} //= $self->{lei}->{sto}->search;
	my $lms = $self->{-lms_ro} //= $self->{lei}->lms; # may be 0 or undef
	my @oidbin = $lms ? $lms->name_oidbin($folder, $bn) : ();
	@oidbin > 1 and $self->{lei}->err("W: $folder/*/$$bn not unique:\n",
				map { "\t".unpack('H*', $_)."\n" } @oidbin);
	my %seen;
	my @docids = sort { $a <=> $b } grep { !$seen{$_}++ }
			map { $lse->over->oidbin_exists($_) } @oidbin;
	my $vmd = $self->{-import_kw} ? { kw => $kw } : undef;
	if (scalar @docids) {
		$lse->kw_changed(undef, $kw, \@docids) or return;
	}
	if (my $eml = eml_from_path($f)) {
		$vmd->{sync_info} = [ $folder, \$bn ] if $self->{-mail_sync};
		$self->input_eml_cb($eml, $vmd);
	}
}

sub input_net_cb { # imap_each / nntp_each
	my ($uri, $uid, $kw, $eml, $self) = @_;
	if (defined $eml) {
		my $vmd = $self->{-import_kw} ? { kw => $kw } : undef;
		$vmd->{sync_info} = [ $$uri, $uid ] if $self->{-mail_sync};
		$self->input_eml_cb($eml, $vmd);
	} elsif (my $ikw = $self->{lei}->{ikw}) { # old message, kw only
		# we send $uri as a bare SCALAR and not a URIimap ref to
		# reduce socket traffic:
		$ikw->wq_io_do('ck_update_kw', [], $$uri, $uid, $kw);
	}
}

sub do_import_index ($$@) {
	my ($self, $lei, @inputs) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	$self->{-import_kw} = $lei->{opt}->{kw} // 1;
	my $vmd_mod = $self->vmd_mod_extract(\@inputs);
	return $lei->fail(join("\n", @{$vmd_mod->{err}})) if $vmd_mod->{err};
	$self->{all_vmd} = $vmd_mod if scalar keys %$vmd_mod;
	$lei->ale; # initialize for workers to read (before LeiPmdir->new)
	$self->{-mail_sync} = $lei->{opt}->{'mail-sync'} // 1;
	$self->prepare_inputs($lei, \@inputs) or return;

	my $j = $lei->{opt}->{jobs} // 0;
	$j =~ /\A([0-9]+),[0-9]+\z/ and $j = $1 + 0;
	$j ||= scalar(@{$self->{inputs}}) || 1;
	my $ikw;
	my $net = $lei->{net};
	if ($net) {
		# $j = $net->net_concurrency($j); TODO
		if ($lei->{opt}->{incremental} // 1) {
			$net->{incremental} = 1;
			$net->{-lms_ro} = $lei->lms // 0;
			if ($self->{-import_kw} && $net->{-lms_ro} &&
					!$lei->{opt}->{'new-only'} &&
					$net->{imap_order}) {
				require PublicInbox::LeiImportKw;
				$ikw = PublicInbox::LeiImportKw->new($lei);
				$net->{each_old} = 1;
			}
		}
	} else {
		my $nproc = $self->detect_nproc;
		$j = $nproc if $j > $nproc;
	}
	if ($lei->{opt}->{'new-only'} && (!$net || !$net->{imap_order})) {
		$lei->err('# --new-only is only for IMAP');
	}
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$lei->{-eml_noisy} = 1;
	(my $op_c, $ops) = $lei->workers_start($self, $j, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops);
}

sub lei_import { # the main "lei import" method
	my ($lei, @inputs) = @_;
	my $self = bless {}, __PACKAGE__;
	do_import_index($self, $lei, @inputs);
}

sub _complete_import {
	my ($lei, @argv) = @_;
	my $match_cb = $lei->complete_url_prepare(\@argv);
	my @m = map { $match_cb->($_) } $lei->url_folder_cache->keys;
	my %f = map { $_ => 1 } @m;
	if (my $lms = $lei->lms) {
		@m = map { $match_cb->($_) } $lms->folders;
		@f{@m} = @m;
	}
	keys %f;
}

no warnings 'once';
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
