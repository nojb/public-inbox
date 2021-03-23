# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles "lei mark" command
package PublicInbox::LeiMark;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::Eml;
use PublicInbox::PktOp qw(pkt_do);

# JMAP RFC 8621 4.1.1
my @KW = (qw(seen answered flagged draft), # system
	qw(forwarded phishing junk notjunk)); # reserved
# note: RFC 8621 states "Users may add arbitrary keywords to an Email",
# but is it good idea?  Stick to the system and reserved ones, for now.
# The "system" ones map to Maildir flags and mbox Status/X-Status headers.
my %KW = map { $_ => 1 } @KW;
my $L_MAX = 244; # Xapian term limit - length('L')

# RFC 8621, sec 2 (Mailboxes) a "label" for us is a JMAP Mailbox "name"
# "Servers MAY reject names that violate server policy"
my %ERR = (
	L => sub {
		my ($label) = @_;
		length($label) >= $L_MAX and
			return "`$label' too long (must be <= $L_MAX)";
		$label =~ m{\A[a-z0-9_][a-z0-9_\-\./\@\!,]*[a-z0-9]\z} ?
			undef : "`$label' is invalid";
	},
	kw => sub {
		my ($kw) = @_;
		$KW{$kw} ? undef : <<EOM;
`$kw' is not one of: `seen', `flagged', `answered', `draft'
`junk', `notjunk', `phishing' or `forwarded'
EOM

	}
);

# like Getopt::Long, but for +kw:FOO and -kw:FOO to prepare
# for update_xvmd -> update_vmd
sub vmd_mod_extract {
	my $argv = $_[-1];
	my $vmd_mod = {};
	my @new_argv;
	for my $x (@$argv) {
		if ($x =~ /\A(\+|\-)(kw|L):(.+)\z/) {
			my ($op, $pfx, $val) = ($1, $2, $3);
			if (my $err = $ERR{$pfx}->($val)) {
				push @{$vmd_mod->{err}}, $err;
			} else { # set "+kw", "+L", "-L", "-kw"
				push @{$vmd_mod->{$op.$pfx}}, $val;
			}
		} else {
			push @new_argv, $x;
		}
	}
	@$argv = @new_argv;
	$vmd_mod;
}

sub eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml) = @_;
	if (my $xoids = $self->{lei}->{ale}->xoids_for($eml)) {
		$self->{lei}->{sto}->ipc_do('update_xvmd', $xoids,
						$self->{vmd_mod});
	} else {
		++$self->{missing};
	}
}

sub mbox_cb { eml_cb($_[1], $_[0]) } # used by PublicInbox::LeiInput::input_fh

sub mark_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($mark, $lei) = @$arg;
	$lei->child_error($?, 'non-fatal errors during mark') if $?;
	my $sto = delete $lei->{sto};
	my $wait = $sto->ipc_do('done') if $sto; # PublicInbox::LeiStore::done
	$lei->dclose;
}

sub mark_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $mark = delete $lei->{mark} or return;
	$mark->wq_wait_old(\&mark_done_wait, $lei);
}

sub net_merge_complete { # callback used by LeiAuth
	my ($self) = @_;
	for my $input (@{$self->{inputs}}) {
		$self->wq_io_do('mark_path_url', [], $input);
	}
	$self->wq_close(1);
}

sub _mark_maildir { # maildir_each_eml cb
	my ($f, $kw, $eml, $self) = @_;
	eml_cb($self, $eml);
}

sub _mark_net { # imap_each, nntp_each cb
	my ($url, $uid, $kw, $eml, $self) = @_;
	eml_cb($self, $eml)
}

sub lei_mark { # the "lei mark" method
	my ($lei, @argv) = @_;
	my $sto = $lei->_lei_store(1);
	my $self = $lei->{mark} = bless { missing => 0 }, __PACKAGE__;
	$sto->write_prepare($lei);
	$lei->ale; # refresh and prepare
	my $vmd_mod = vmd_mod_extract(\@argv);
	return $lei->fail(join("\n", @{$vmd_mod->{err}})) if $vmd_mod->{err};
	$self->prepare_inputs($lei, \@argv) or return;
	grep(defined, @$vmd_mod{qw(+kw +L -L -kw)}) or
		return $lei->fail('no keywords or labels specified');
	my $ops = { '' => [ \&mark_done, $lei ] };
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{vmd_mod} = $vmd_mod;
	my $op = $lei->workers_start($self, 'lei_mark', 1, $ops);
	$self->wq_io_do('mark_stdin', []) if $self->{0};
	net_merge_complete($self) unless $lei->{auth};
	while ($op && $op->{sock}) { $op->event_step }
}

sub mark_path_url {
	my ($self, $input) = @_;
	my $lei = $self->{lei};
	my $ifmt = lc($lei->{opt}->{'in-format'} // '');
	# TODO auto-detect?
	if ($input =~ m!\Aimaps?://!i) {
		$lei->{net}->imap_each($input, \&_mark_net, $self);
		return;
	} elsif ($input =~ m!\A(?:nntps?|s?news)://!i) {
		$lei->{net}->nntp_each($input, \&_mark_net, $self);
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
					\&_mark_maildir, $self);
	} else {
		$lei->fail("$input unsupported (TODO)");
	}
}

sub mark_stdin {
	my ($self) = @_;
	my $lei = $self->{lei};
	my $in = delete $self->{0};
	$self->input_fh($lei->{opt}->{'in-format'}, $in, '<stdin>');
}

sub note_missing {
	my ($self) = @_;
	$self->{lei}->child_error(1 << 8) if $self->{missing};
}

sub ipc_atfork_child {
	my ($self) = @_;
	PublicInbox::LeiInput::input_only_atfork_child($self);
	# this goes out-of-scope at worker process exit:
	PublicInbox::OnDestroy->new($$, \&note_missing, $self);
}

1;
