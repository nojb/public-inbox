# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei import" sub-command
package PublicInbox::LeiImport;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Eml;
use PublicInbox::InboxWritable qw(eml_from_path);

sub _import_eml { # MboxReader callback
	my ($eml, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml', $eml, $set_kw ? $sto->mbox_keywords($eml) : ());
}

sub import_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($imp, $lei) = @$arg;
	$lei->child_error($?, 'non-fatal errors during import') if $?;
	my $ign = $lei->{sto}->ipc_do('done'); # PublicInbox::LeiStore::done
	$lei->dclose;
}

sub import_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $imp = delete $lei->{imp} or return;
	$imp->wq_wait_old(\&import_done_wait, $lei);
}

sub import_start {
	my ($lei) = @_;
	my $self = $lei->{imp};
	my $j = $lei->{opt}->{jobs} // scalar(@{$self->{inputs}}) || 1;
	if (my $nrd = $lei->{nrd}) {
		# $j = $nrd->net_concurrency($j); TODO
	} else {
		my $nproc = $self->detect_nproc;
		$j = $nproc if $j > $nproc;
	}
	my $op = $lei->workers_start($self, 'lei_import', $j, {
		'' => [ \&import_done, $lei ],
	});
	$self->wq_io_do('import_stdin', []) if $self->{0};
	for my $input (@{$self->{inputs}}) {
		$self->wq_io_do('import_path_url', [], $input);
	}
	$self->wq_close(1);
	while ($op && $op->{sock}) { $op->event_step }
}

sub call { # the main "lei import" method
	my ($cls, $lei, @inputs) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	my ($nrd, @f, @d);
	$lei->{opt}->{kw} //= 1;
	my $self = $lei->{imp} = bless { inputs => \@inputs }, $cls;
	if ($lei->{opt}->{stdin}) {
		@inputs and return $lei->fail("--stdin and @inputs do not mix");
		$lei->check_input_format or return;
		$self->{0} = $lei->{0};
	}

	# TODO: do we need --format for non-stdin?
	my $fmt = $lei->{opt}->{'format'};
	# e.g. Maildir:/home/user/Mail/ or imaps://example.com/INBOX
	for my $input (@inputs) {
		my $input_path = $input;
		if ($input =~ m!\A(?:imap|nntp)s?://!i) {
			require PublicInbox::NetReader;
			$nrd //= PublicInbox::NetReader->new;
			$nrd->add_url($input);
		} elsif ($input_path =~ s/\A([a-z0-9]+)://is) {
			my $ifmt = lc $1;
			if (($fmt // $ifmt) ne $ifmt) {
				return $lei->fail(<<"");
--format=$fmt and `$ifmt:' conflict

			}
			if (-f $input_path) {
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
	return import_start($lei) if !$nrd;

	if (my $err = $nrd->errors) {
		return $lei->fail($err);
	}
	$nrd->{quiet} = $lei->{opt}->{quiet};
	$lei->{nrd} = $nrd;
	require PublicInbox::LeiAuth;
	my $auth = $lei->{auth} = PublicInbox::LeiAuth->new($nrd);
	$auth->auth_start($lei, \&import_start, $lei);
}

sub ipc_atfork_child {
	my ($self) = @_;
	delete $self->{lei}->{imp}; # drop circular ref
	$self->{lei}->lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
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
	$lei->child_error(1 << 8, "<stdin>: $@") if $@;
}

sub _import_maildir { # maildir_each_file cb
	my ($f, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml_from_maildir', $f, $set_kw);
}

sub _import_imap { # imap_each cb
	my ($url, $uid, $kw, $eml, $sto, $set_kw) = @_;
	warn "$url $uid";
	$sto->ipc_do('set_eml', $eml, $set_kw ? @$kw : ());
}

sub import_path_url {
	my ($self, $input) = @_;
	my $lei = $self->{lei};
	my $ifmt = lc($lei->{opt}->{'format'} // '');
	# TODO auto-detect?
	if ($input =~ m!\A(imap|nntp)s?://!i) {
		$lei->{nrd}->imap_each($input, \&_import_imap, $lei->{sto},
					$lei->{opt}->{kw});
		return;
	} elsif ($input =~ s!\A([a-z0-9]+):!!i) {
		$ifmt = lc $1;
	}
	if (-f $input) {
		open my $fh, '<', $input or return $lei->child_error(1 << 8, <<"");
unable to open $input: $!

		_import_fh($lei, $fh, $input, $ifmt);
	} elsif (-d _ && (-d "$input/cur" || -d "$input/new")) {
		return $lei->fail(<<EOM) if $ifmt && $ifmt ne 'maildir';
$input appears to a be a maildir, not $ifmt
EOM
		PublicInbox::MdirReader::maildir_each_file($input,
					\&_import_maildir,
					$lei->{sto}, $lei->{opt}->{kw});
	} else {
		$lei->fail("$input unsupported (TODO)");
	}
}

sub import_stdin {
	my ($self) = @_;
	my $lei = $self->{lei};
	_import_fh($lei, delete $self->{0}, '<stdin>', $lei->{opt}->{'format'});
}

1;
