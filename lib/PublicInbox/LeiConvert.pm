# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei convert" sub-command
package PublicInbox::LeiConvert;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use PublicInbox::Eml;
use PublicInbox::InboxWritable qw(eml_from_path);
use PublicInbox::PktOp;
use PublicInbox::LeiStore;
use PublicInbox::LeiOverview;

sub mbox_cb {
	my ($eml, $self) = @_;
	my @kw = PublicInbox::LeiStore::mbox_keywords($eml);
	$eml->header_set($_) for qw(Status X-Status);
	$self->{wcb}->(undef, { kw => \@kw }, $eml);
}

sub imap_cb { # ->imap_each
	my ($url, $uid, $kw, $eml, $self) = @_;
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub mdir_cb {
	my ($kw, $eml, $self) = @_;
	$self->{wcb}->(undef, { kw => $kw }, $eml);
}

sub do_convert { # via wq_do
	my ($self) = @_;
	my $lei = $self->{lei};
	my $in_fmt = $lei->{opt}->{'in-format'};
	if (my $stdin = delete $self->{0}) {
		PublicInbox::MboxReader->$in_fmt($stdin, \&mbox_cb, $self);
	}
	for my $input (@{$self->{inputs}}) {
		my $ifmt = lc($in_fmt // '');
		if ($input =~ m!\A(?:imap|nntp)s?://!) { # TODO: nntp
			$lei->{nrd}->imap_each($input, \&imap_cb, $self);
			next;
		} elsif ($input =~ s!\A([a-z0-9]+):!!i) {
			$ifmt = lc $1;
		}
		if (-f $input) {
			open my $fh, '<', $input or
					return $lei->fail("open $input: $!");
			PublicInbox::MboxReader->$ifmt($fh, \&mbox_cb, $self);
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

sub convert_start {
	my ($lei) = @_;
	my $ops = {
		'!' => [ $lei->can('fail_handler'), $lei ],
		'|' => [ $lei->can('sigpipe_handler'), $lei ],
		'x_it' => [ $lei->can('x_it'), $lei ],
		'child_error' => [ $lei->can('child_error'), $lei ],
		'' => [ $lei->can('dclose'), $lei ],
	};
	($lei->{pkt_op_c}, $lei->{pkt_op_p}) = PublicInbox::PktOp->pair($ops);
	my $self = $lei->{cnv};
	$self->wq_workers_start('lei_convert', 1, $lei->oldset, {lei => $lei});
	my $op = delete $lei->{pkt_op_c};
	delete $lei->{pkt_op_p};
	$self->wq_io_do('do_convert', []);
	$self->wq_close(1);
	$lei->event_step_init; # wait for shutdowns
	if ($lei->{oneshot}) {
		while ($op->{sock}) { $op->event_step }
	}
}

sub call { # the main "lei convert" method
	my ($cls, $lei, @inputs) = @_;
	my $opt = $lei->{opt};
	$opt->{kw} //= 1;
	my $self = $lei->{cnv} = bless {}, $cls;
	my $in_fmt = $opt->{'in-format'};
	my ($nrd, @f, @d);
	$opt->{dedupe} //= 'none';
	my $ovv = PublicInbox::LeiOverview->new($lei, 'out-format');
	$lei->{l2m} or return
		$lei->fail("output not specified or is not a mail destination");
	$opt->{augment} = 1 unless $ovv->{dst} eq '/dev/stdout';
	if ($opt->{stdin}) {
		@inputs and return $lei->fail("--stdin and @inputs do not mix");
		$lei->check_input_format(undef, 'in-format') or return;
		$self->{0} = $lei->{0};
	}
	# e.g. Maildir:/home/user/Mail/ or imaps://example.com/INBOX
	for my $input (@inputs) {
		my $input_path = $input;
		if ($input =~ m!\A(?:imap|nntp)s?://!i) {
			require PublicInbox::NetReader;
			$nrd //= PublicInbox::NetReader->new;
			$nrd->add_url($input);
		} elsif ($input_path =~ s/\A([a-z0-9]+)://is) {
			my $ifmt = lc $1;
			if (($in_fmt // $ifmt) ne $ifmt) {
				return $lei->fail(<<"");
--in-format=$in_fmt and `$ifmt:' conflict

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
		} elsif (-f $input) { push @f, $input }
		elsif (-d _) { push @d, $input }
		else { return $lei->fail("Unable to handle $input") }
	}
	if (@f) { $lei->check_input_format(\@f, 'in-format') or return }
	if (@d) { # TODO: check for MH vs Maildir, here
		require PublicInbox::MdirReader;
	}
	$self->{inputs} = \@inputs;
	return convert_start($lei) if !$nrd;

	if (my $err = $nrd->errors) {
		return $lei->fail($err);
	}
	$nrd->{quiet} = $opt->{quiet};
	$lei->{nrd} = $nrd;
	require PublicInbox::LeiAuth;
	my $auth = $lei->{auth} = PublicInbox::LeiAuth->new($nrd);
	$auth->auth_start($lei, \&convert_start, $lei);
}

sub ipc_atfork_child {
	my ($self) = @_;
	my $lei = $self->{lei};
	$lei->lei_atfork_child;
	my $l2m = delete $lei->{l2m};
	$l2m->pre_augment($lei);
	$l2m->do_augment($lei);
	$l2m->post_augment($lei);
	$self->{wcb} = $l2m->write_cb($lei);
	$SIG{__WARN__} = PublicInbox::Eml::warn_ignore_cb();
	$self->SUPER::ipc_atfork_child;
}

1;
