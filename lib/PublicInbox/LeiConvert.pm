# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei convert" sub-command
package PublicInbox::LeiConvert;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::LeiOverview;
use PublicInbox::DS;

# /^input_/ subs are used by PublicInbox::LeiInput

sub input_mbox_cb { # MboxReader callback
	my ($eml, $self) = @_;
	my $kw = PublicInbox::MboxReader::mbox_keywords($eml);
	$eml->header_set($_) for qw(Status X-Status);
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml) = @_;
	$self->{wcb}->(undef, {}, $eml);
}

sub input_net_cb { # callback for ->imap_each, ->nntp_each
	my (undef, undef, $kw, $eml, $self) = @_; # @_[0,1]: url + uid ignored
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub input_maildir_cb {
	my (undef, $kw, $eml, $self) = @_; # $_[0] $filename ignored
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub process_inputs { # via wq_do
	my ($self) = @_;
	local $PublicInbox::DS::in_loop = 0; # force synchronous dwaitpid
	$self->SUPER::process_inputs;
	my $lei = $self->{lei};
	delete $lei->{1};
	delete $self->{wcb}; # commit
	my $nr = delete($lei->{-nr_write}) // 0;
	$lei->qerr("# converted $nr messages");
}

sub lei_convert { # the main "lei convert" method
	my ($lei, @inputs) = @_;
	$lei->{opt}->{kw} //= 1;
	$lei->{opt}->{dedupe} //= 'none';
	my $self = bless {}, __PACKAGE__;
	my $ovv = PublicInbox::LeiOverview->new($lei, 'out-format');
	$lei->{l2m} or return
		$lei->fail("output not specified or is not a mail destination");
	my $devfd = $lei->path_to_fd($ovv->{dst}) // return;
	$lei->{opt}->{augment} = 1 if $devfd < 0;
	$self->prepare_inputs($lei, \@inputs) or return;
	# n.b. {net} {auth} is handled by l2m worker
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	$self->wq_io_do('process_inputs', []);
	$self->wq_close;
	$lei->wait_wq_events($op_c, $ops);
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->_lei_atfork_child;
	my $l2m = delete $lei->{l2m};
	if (my $net = $lei->{net}) { # may prompt user once
		$net->{mics_cached} = $net->imap_common_init($lei);
		$net->{nn_cached} = $net->nntp_common_init($lei);
	}
	$l2m->pre_augment($lei);
	$l2m->do_augment($lei);
	$l2m->post_augment($lei);
	$self->{wcb} = $l2m->write_cb($lei);
	$self->SUPER::ipc_atfork_child;
}

1;
