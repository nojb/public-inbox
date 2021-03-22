# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei convert" sub-command
package PublicInbox::LeiConvert;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::Eml;
use PublicInbox::LeiStore;
use PublicInbox::LeiOverview;

sub mbox_cb {
	my ($eml, $self) = @_;
	my $kw = PublicInbox::MboxReader::mbox_keywords($eml);
	$eml->header_set($_) for qw(Status X-Status);
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub net_cb { # callback for ->imap_each, ->nntp_each
	my (undef, undef, $kw, $eml, $self) = @_; # @_[0,1]: url + uid ignored
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub mdir_cb {
	my ($f, $kw, $eml, $self) = @_;
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub convert_fh ($$$$) {
	my ($self, $ifmt, $fh, $name) = @_;
	if ($ifmt eq 'eml') {
		my $buf = do { local $/; <$fh> } //
			return $self->{lei}->child_error(1 << 8, <<"");
error reading $name: $!

		my $eml = PublicInbox::Eml->new(\$buf);
		$self->{wcb}->(undef, { kw => [] }, $eml);
	} else {
		PublicInbox::MboxReader->$ifmt($fh, \&mbox_cb, $self);
	}
}

sub do_convert { # via wq_do
	my ($self) = @_;
	my $lei = $self->{lei};
	my $in_fmt = $lei->{opt}->{'in-format'};
	my $mics;
	if (my $stdin = delete $self->{0}) {
		convert_fh($self, $in_fmt, $stdin, '<stdin>');
	}
	for my $input (@{$self->{inputs}}) {
		my $ifmt = lc($in_fmt // '');
		if ($input =~ m!\Aimaps?://!) {
			$lei->{net}->imap_each($input, \&net_cb, $self);
			next;
		} elsif ($input =~ m!\A(?:nntps?|s?news)://!) {
			$lei->{net}->nntp_each($input, \&net_cb, $self);
			next;
		} elsif ($input =~ s!\A([a-z0-9]+):!!i) {
			$ifmt = lc $1;
		}
		if (-f $input) {
			my $m = $lei->{opt}->{'lock'} //
					($ifmt eq 'eml' ? ['none'] :
					PublicInbox::MboxLock->defaults);
			my $mbl = PublicInbox::MboxLock->acq($input, 0, $m);
			convert_fh($self, $ifmt, $mbl->{fh}, $input);
		} elsif (-d _) {
			PublicInbox::MdirReader::maildir_each_eml($input,
							\&mdir_cb, $self);
		} else {
			die "BUG: $input unhandled"; # should've failed earlier
		}
	}
	delete $lei->{1};
	delete $self->{wcb}; # commit
}

sub lei_convert { # the main "lei convert" method
	my ($lei, @inputs) = @_;
	$lei->{opt}->{kw} //= 1;
	$lei->{opt}->{dedupe} //= 'none';
	my $self = $lei->{cnv} = bless {}, __PACKAGE__;
	my $ovv = PublicInbox::LeiOverview->new($lei, 'out-format');
	$lei->{l2m} or return
		$lei->fail("output not specified or is not a mail destination");
	$lei->{opt}->{augment} = 1 unless $ovv->{dst} eq '/dev/stdout';
	$self->prepare_inputs($lei, \@inputs) or return;
	my $op = $lei->workers_start($self, 'lei_convert', 1, {
		'' => [ $lei->can('dclose'), $lei ]
	});
	$self->wq_io_do('do_convert', []);
	$self->wq_close(1);
	while ($op && $op->{sock}) { $op->event_step }
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->lei_atfork_child;
	my $l2m = delete $lei->{l2m};
	if (my $net = $lei->{net}) { # may prompt user once
		$net->{mics_cached} = $net->imap_common_init($lei);
		$net->{nn_cached} = $net->nntp_common_init($lei);
	}
	$SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$l2m->pre_augment($lei);
	$l2m->do_augment($lei);
	$l2m->post_augment($lei);
	$self->{wcb} = $l2m->write_cb($lei);
	$self->SUPER::ipc_atfork_child;
}

1;
