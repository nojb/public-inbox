# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles "lei tag" command
package PublicInbox::LeiTag;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);

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
		$label =~ m{\A[a-z0-9_](?:[a-z0-9_\-\./\@,]*[a-z0-9])?\z}i ?
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

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml) = @_;
	if (my $xoids = $self->{lei}->{ale}->xoids_for($eml)) {
		$self->{lei}->{sto}->ipc_do('update_xvmd', $xoids, $eml,
						$self->{vmd_mod});
	} else {
		++$self->{missing};
	}
}

sub input_mbox_cb { input_eml_cb($_[1], $_[0]) }

sub tag_done_wait { # dwaitpid callback
	my ($arg, $pid) = @_;
	my ($tag, $lei) = @$arg;
	$lei->child_error($?, 'non-fatal errors during tag') if $?;
	$lei->dclose;
}

sub tag_done { # EOF callback for main daemon
	my ($lei) = @_;
	my $tag = delete $lei->{tag} or return;
	$tag->wq_wait_old(\&tag_done_wait, $lei);
}

sub net_merge_complete { # callback used by LeiAuth
	my ($self) = @_;
	$self->wq_io_do('process_inputs');
	$self->wq_close(1);
}

sub input_maildir_cb { # maildir_each_eml cb
	my ($f, $kw, $eml, $self) = @_;
	input_eml_cb($self, $eml);
}

sub input_net_cb { # imap_each, nntp_each cb
	my ($url, $uid, $kw, $eml, $self) = @_;
	input_eml_cb($self, $eml);
}

sub lei_tag { # the "lei tag" method
	my ($lei, @argv) = @_;
	my $sto = $lei->_lei_store(1);
	$sto->write_prepare($lei);
	my $self = bless { missing => 0 }, __PACKAGE__;
	$lei->ale; # refresh and prepare
	my $vmd_mod = vmd_mod_extract(\@argv);
	return $lei->fail(join("\n", @{$vmd_mod->{err}})) if $vmd_mod->{err};
	$self->prepare_inputs($lei, \@argv) or return;
	grep(defined, @$vmd_mod{qw(+kw +L -L -kw)}) or
		return $lei->fail('no keywords or labels specified');
	my $ops = { '' => [ \&tag_done, $lei ] };
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	$self->{vmd_mod} = $vmd_mod;
	(my $op_c, $ops) = $lei->workers_start($self, 'lei_tag', 1, $ops);
	$lei->{tag} = $self;
	net_merge_complete($self) unless $lei->{auth};
	$op_c->op_wait_event($ops);
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

# Workaround bash word-splitting s to ['kw', ':', 'keyword' ...]
# Maybe there's a better way to go about this in
# contrib/completion/lei-completion.bash
sub _complete_mark_common ($) {
	my ($argv) = @_;
	# Workaround bash word-splitting URLs to ['https', ':', '//' ...]
	# Maybe there's a better way to go about this in
	# contrib/completion/lei-completion.bash
	my $re = '';
	my $cur = pop(@$argv) // '';
	if (@$argv) {
		my @x = @$argv;
		if ($cur eq ':' && @x) {
			push @x, $cur;
			$cur = '';
		}
		while (@x > 2 && $x[0] !~ /\A[+\-](?:kw|L)\z/ &&
					$x[1] ne ':') {
			shift @x;
		}
		if (@x >= 2) { # qw(kw : $KEYWORD) or qw(kw :)
			$re = join('', @x);
		} else { # just return everything and hope for the best
			$re = join('', @$argv);
		}
		$re = quotemeta($re);
	}
	($cur, $re);
}

# FIXME: same problems as _complete_forget_external and similar
sub _complete_tag {
	my ($self, @argv) = @_;
	my @L = eval { $self->_lei_store->search->all_terms('L') };
	my @all = ((map { ("+kw:$_", "-kw:$_") } @KW),
		(map { ("+L:$_", "-L:$_") } @L));
	return @all if !@argv;
	my ($cur, $re) = _complete_mark_common(\@argv);
	map {
		# only return the part specified on the CLI
		# don't duplicate if already 100% completed
		/\A$re(\Q$cur\E.*)/ ? ($cur eq $1 ? () : $1) : ();
	} grep(/$re\Q$cur/, @all);
}

1;
