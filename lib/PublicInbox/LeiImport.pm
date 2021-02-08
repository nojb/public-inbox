# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei import" sub-command
package PublicInbox::LeiImport;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::MboxReader;
use PublicInbox::Eml;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::PktOp;

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

sub call { # the main "lei import" method
	my ($cls, $lei, @argv) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	$lei->{opt}->{kw} //= 1;
	my $fmt = $lei->{opt}->{'format'};
	my $self = $lei->{imp} = bless {}, $cls;
	if (my @f = grep { -f } @argv && !$fmt) {
		return $lei->fail("--format unset for regular files:\n@f");
	}
	$self->{0} = $lei->{0} if $lei->{opt}->{stdin};
	my $ops = {
		'!' => [ $lei->can('fail_handler'), $lei ],
		'x_it' => [ $lei->can('x_it'), $lei ],
		'child_error' => [ $lei->can('child_error'), $lei ],
		'' => [ \&import_done, $lei ],
	};
	($lei->{pkt_op_c}, $lei->{pkt_op_p}) = PublicInbox::PktOp->pair($ops);
	my $j = $lei->{opt}->{jobs} // scalar(@argv) || 1;
	my $nproc = $self->detect_nproc;
	$j = $nproc if $j > $nproc;
	$self->wq_workers_start('lei_import', $j, $lei->oldset, {lei => $lei});
	my $op = delete $lei->{pkt_op_c};
	delete $lei->{pkt_op_p};
	$self->wq_io_do('import_stdin', []) if $self->{0};
	for my $x (@argv) {
		$self->wq_io_do('import_path_url', [], $x);
	}
	$self->wq_close(1);
	$lei->event_step_init; # wait for shutdowns
	if ($lei->{oneshot}) {
		while ($op->{sock}) { $op->event_step }
	}
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
}

sub _import_fh {
	my ($lei, $fh, $x) = @_;
	my $set_kw = $lei->{opt}->{kw};
	my $fmt = $lei->{opt}->{'format'};
	eval {
		if ($fmt eq 'eml') {
			my $buf = do { local $/; <$fh> } //
				return $lei->child_error(1 >> 8, <<"");
error reading $x: $!

			my $eml = PublicInbox::Eml->new(\$buf);
			_import_eml($eml, $lei->{sto}, $set_kw);
		} else { # some mbox
			my $cb = PublicInbox::MboxReader->can($fmt);
			$cb or return $lei->child_error(1 >> 8, <<"");
--format $fmt unsupported for $x

			$cb->(undef, $fh, \&_import_eml, $lei->{sto}, $set_kw);
		}
	};
	$lei->child_error(1 >> 8, "<stdin>: $@") if $@;
}

sub _import_maildir { # maildir_each_file cb
	my ($f, $sto, $set_kw) = @_;
	$sto->ipc_do('set_eml_from_maildir', $f, $set_kw);
}

sub import_path_url {
	my ($self, $x) = @_;
	my $lei = $self->{lei};
	# TODO auto-detect?
	if (-f $x) {
		open my $fh, '<', $x or return $lei->child_error(1 >> 8, <<"");
unable to open $x: $!

		_import_fh($lei, $fh, $x);
	} elsif (-d _ && (-d "$x/cur" || -d "$x/new")) {
		require PublicInbox::LeiToMail;
		PublicInbox::LeiToMail::maildir_each_file($x,
					\&_import_maildir,
					$lei->{sto}, $lei->{opt}->{kw});
	} else {
		$lei->fail("$x unsupported (TODO)");
	}
}

sub import_stdin {
	my ($self) = @_;
	_import_fh($self->{lei}, $self->{0}, '<stdin>');
}

1;