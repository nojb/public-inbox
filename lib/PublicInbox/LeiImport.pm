# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei import" sub-command
package PublicInbox::LeiImport;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Eml;
use PublicInbox::PktOp qw(pkt_do);

sub _import_eml { # MboxReader callback
	my ($eml, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml', $eml, $set_kw ?
		@{PublicInbox::MboxReader::mbox_keywords($eml)} : ());
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

sub call { # the main "lei import" method
	my ($cls, $lei, @inputs) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	my ($net, @f, @d);
	$lei->{opt}->{kw} //= 1;
	my $self = $lei->{imp} = bless { inputs => \@inputs }, $cls;
	if ($lei->{opt}->{stdin}) {
		@inputs and return $lei->fail("--stdin and @inputs do not mix");
		$lei->check_input_format or return;
		$self->{0} = $lei->{0};
	}

	my $fmt = $lei->{opt}->{'in-format'};
	# e.g. Maildir:/home/user/Mail/ or imaps://example.com/INBOX
	for my $input (@inputs) {
		my $input_path = $input;
		if ($input =~ m!\A(?:imaps?|nntps?|s?news)://!i) {
			require PublicInbox::NetReader;
			$net //= PublicInbox::NetReader->new;
			$net->add_url($input);
		} elsif ($input_path =~ s/\A([a-z0-9]+)://is) {
			my $ifmt = lc $1;
			if (($fmt // $ifmt) ne $ifmt) {
				return $lei->fail(<<"");
--in-format=$fmt and `$ifmt:' conflict

			}
			if (-f $input_path) {
				require PublicInbox::MboxLock;
				require PublicInbox::MboxReader;
				PublicInbox::MboxReader->can($ifmt) or return
					$lei->fail("$ifmt not supported");
			} elsif (-d _) {
				require PublicInbox::MdirReader;
				$ifmt eq 'maildir' or return
					$lei->fail("$ifmt not supported");
			} else {
				return $lei->fail("Unable to handle $input");
			}
		} elsif (-f $input) { push @f, $input
		} elsif (-d _) { push @d, $input
		} else { return $lei->fail("Unable to handle $input") }
	}
	if (@f) { $lei->check_input_format(\@f) or return }
	if (@d) { # TODO: check for MH vs Maildir, here
		require PublicInbox::MdirReader;
	}
	$self->{inputs} = \@inputs;
	if ($net) {
		if (my $err = $net->errors) {
			return $lei->fail($err);
		}
		$net->{quiet} = $lei->{opt}->{quiet};
		$lei->{net} = $net;
		require PublicInbox::LeiAuth;
		$lei->{auth} = PublicInbox::LeiAuth->new;
	}
	import_start($lei);
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	delete $lei->{imp}; # drop circular ref
	$lei->lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
	$lei->{auth}->do_auth_atfork($self) if $lei->{auth};
	undef;
}

sub _import_fh {
	my ($lei, $fh, $input, $ifmt) = @_;
	my $set_kw = $lei->{opt}->{kw};
	eval {
		if ($ifmt eq 'eml') {
			my $buf = do { local $/; <$fh> } //
				return $lei->child_error(1 << 8, <<"");
error reading $input: $!

			my $eml = PublicInbox::Eml->new(\$buf);
			_import_eml($eml, $lei->{sto}, $set_kw);
		} else { # some mbox (->can already checked in call);
			my $cb = PublicInbox::MboxReader->can($ifmt) //
				die "BUG: bad fmt=$ifmt";
			$cb->(undef, $fh, \&_import_eml, $lei->{sto}, $set_kw);
		}
	};
	$lei->child_error(1 << 8, "$input: $@") if $@;
}

sub _import_maildir { # maildir_each_eml cb
	my ($f, $kw, $eml, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml', $eml, $set_kw ? @$kw : ());
}

sub _import_net { # imap_each, nntp_each cb
	my ($url, $uid, $kw, $eml, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml', $eml, $set_kw ? @$kw : ());
}

sub import_path_url {
	my ($self, $input) = @_;
	my $lei = $self->{lei};
	my $ifmt = lc($lei->{opt}->{'in-format'} // '');
	# TODO auto-detect?
	if ($input =~ m!\Aimaps?://!i) {
		$lei->{net}->imap_each($input, \&_import_net, $lei->{sto},
					$lei->{opt}->{kw});
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
		_import_fh($lei, $mbl->{fh}, $input, $ifmt);
	} elsif (-d _ && (-d "$input/cur" || -d "$input/new")) {
		return $lei->fail(<<EOM) if $ifmt && $ifmt ne 'maildir';
$input appears to a be a maildir, not $ifmt
EOM
		PublicInbox::MdirReader::maildir_each_eml($input,
					\&_import_maildir,
					$lei->{sto}, $lei->{opt}->{kw});
	} else {
		$lei->fail("$input unsupported (TODO)");
	}
}

sub import_stdin {
	my ($self) = @_;
	my $lei = $self->{lei};
	_import_fh($lei, delete $self->{0}, '<stdin>', $lei->{opt}->{'in-format'});
}

no warnings 'once'; # the following works even when LeiAuth is lazy-loaded
*net_merge_all = \&PublicInbox::LeiAuth::net_merge_all;
1;
