# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# internal command for dealing with inotify, kqueue vnodes, etc
# it is a semi-persistent worker
package PublicInbox::LeiNoteEvent;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::DS;

our $to_flush; # { cfgpath => $lei }

sub flush_lei ($) {
	my ($lei) = @_;
	my $lne = delete $lei->{cfg}->{-lei_note_event};
	$lne->wq_close(1, undef, $lei) if $lne; # runs _lei_wq_eof;
}

# we batch up writes and flush every 5s (matching Linux default
# writeback behavior) since MUAs can trigger a storm of inotify events
sub flush_task { # PublicInbox::DS timer callback
	my $todo = $to_flush // return;
	$to_flush = undef;
	for my $lei (values %$todo) { flush_lei($lei) }
}

# sets a timer to flush
sub note_event_arm_done ($) {
	my ($lei) = @_;
	PublicInbox::DS::add_uniq_timer('flush_timer', 5, \&flush_task);
	$to_flush->{$lei->{cfg}->{'-f'}} //= $lei;
}

sub eml_event ($$$$) {
	my ($self, $eml, $vmd, $state) = @_;
	my $sto = $self->{lei}->{sto};
	if ($state =~ /\Aimport-(?:rw|ro)\z/) {
		$sto->wq_do('set_eml', $eml, $vmd);
	} elsif ($state =~ /\Aindex-(?:rw|ro)\z/) {
		my $xoids = $self->{lei}->ale->xoids_for($eml);
		$sto->wq_do('index_eml_only', $eml, $vmd, $xoids);
	} elsif ($state =~ /\Atag-(?:rw|ro)\z/) {
		my $docids = [];
		my $c = $self->{lse}->kw_changed($eml, $vmd->{kw}, $docids);
		if (scalar @$docids) { # already in lei/store
			$sto->wq_do('set_eml_vmd', undef, $vmd, $docids) if $c;
		} elsif (my $xoids = $self->{lei}->ale->xoids_for($eml)) {
			# it's in an external, only set kw, here
			$sto->wq_do('set_xvmd', $xoids, $eml, $vmd);
		} # else { totally unknown: ignore
	} else {
		warn "unknown state: $state (in $self->{lei}->{cfg}->{'-f'})\n";
	}
}

sub maildir_event { # via wq_io_do
	my ($self, $fn, $vmd, $state) = @_;
	my $eml = PublicInbox::InboxWritable::eml_from_path($fn) // return;
	eml_event($self, $eml, $vmd, $state);
}

sub lei_note_event {
	my ($lei, $folder, $new_cur, $bn, $fn, @rest) = @_;
	die "BUG: unexpected: @rest" if @rest;
	my $cfg = $lei->_lei_cfg or return; # gone (race)
	my $sto = $lei->_lei_store or return; # gone
	return flush_lei($lei) if $folder eq 'done'; # special case
	my $lms = $lei->lms or return;
	$lms->lms_write_prepare if $new_cur eq ''; # for ->clear_src below
	$lei->{opt}->{quiet} = 1;
	eval { $lms->arg2folder($lei, [ $folder ]) };
	return if $@;
	my $state = $cfg->get_1("watch.$folder", 'state') // 'tag-rw';
	return if $state eq 'pause';
	return $lms->clear_src($folder, \$bn) if $new_cur eq '';
	$lms->lms_pause;
	$lei->ale; # prepare
	$sto->write_prepare($lei);
	require PublicInbox::MdirReader;
	my $self = $cfg->{-lei_note_event} //= do {
		my $wq = bless { lms => $lms }, __PACKAGE__;
		# MUAs such as mutt can trigger massive rename() storms so
		# use some CPU, but don't overwhelm slower storage, either
		my $jobs = $wq->detect_nproc // 1;
		$jobs = 4 if $jobs > 4; # same default as V2Writable
		my ($op_c, $ops) = $lei->workers_start($wq, $jobs);
		$lei->wait_wq_events($op_c, $ops);
		note_event_arm_done($lei);
		$lei->{lne} = $wq;
	};
	if ($folder =~ /\Amaildir:/i) {
		my $fl = PublicInbox::MdirReader::maildir_basename_flags($bn)
			// return;
		return if index($fl, 'T') >= 0;
		my $kw = PublicInbox::MdirReader::flags2kw($fl);
		my $vmd = { kw => $kw, sync_info => [ $folder, \$bn ] };
		$self->wq_io_do('maildir_event', [], $fn, $vmd, $state);
	} # else: TODO: imap
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->_lei_atfork_child(1); # persistent, for a while
	$self->{lms}->lms_write_prepare;
	$self->{lse} = $self->{lei}->{sto}->search;
	$self->SUPER::ipc_atfork_child;
}

sub lne_done_wait {
	my ($arg, $pid) = @_;
	my ($self, $lei) = @$arg;
	$lei->can('wq_done_wait')->($arg, $pid);
}

sub _lei_wq_eof { # EOF callback for main lei daemon
	my ($lei) = @_;
	my $lne = delete $lei->{lne} or return $lei->fail;
	$lei->sto_done_request;
	$lne->wq_wait_old(\&lne_done_wait, $lei);
}

1;
