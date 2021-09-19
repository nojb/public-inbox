# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# handles "lei tag" command
package PublicInbox::LeiTag;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::InboxWritable qw(eml_from_path);

sub input_eml_cb { # used by PublicInbox::LeiInput::input_fh
	my ($self, $eml) = @_;
	if (my $xoids = $self->{lse}->xoids_for($eml) // # tries LeiMailSync
			$self->{lei}->{ale}->xoids_for($eml)) {
		$self->{lei}->{sto}->wq_do('update_xvmd', $xoids, $eml,
						$self->{vmd_mod});
	} else {
		++$self->{unimported};
	}
}

sub input_mbox_cb {
	my ($eml, $self) = @_;
	$eml->header_set($_) for (qw(X-Status Status));
	input_eml_cb($self, $eml);
}

sub pmdir_cb { # called via wq_io_do from LeiPmdir->each_mdir_fn
	my ($self, $f) = @_;
	my $eml = eml_from_path($f) or return;
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
	my $self = bless {}, __PACKAGE__;
	$lei->ale; # refresh and prepare
	my $vmd_mod = $self->vmd_mod_extract(\@argv);
	return $lei->fail(join("\n", @{$vmd_mod->{err}})) if $vmd_mod->{err};
	$self->{vmd_mod} = $vmd_mod; # before LeiPmdir->new in prepare_inputs
	$self->prepare_inputs($lei, \@argv) or return;
	grep(defined, @$vmd_mod{qw(+kw +L -L -kw)}) or
		return $lei->fail('no keywords or labels specified');
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self) if $lei->{auth};
	(my $op_c, $ops) = $lei->workers_start($self, 1, $ops);
	$lei->{wq1} = $self;
	$lei->{-err_type} = 'non-fatal';
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops);
}

sub note_unimported {
	my ($self) = @_;
	my $n = $self->{unimported} or return;
	$self->{lei}->{pkt_op_p}->pkt_do('incr', 'unimported', $n);
}

sub ipc_atfork_child {
	my ($self) = @_;
	PublicInbox::LeiInput::input_only_atfork_child($self);
	$self->{lse} = $self->{lei}->{sto}->search;
	# this goes out-of-scope at worker process exit:
	PublicInbox::OnDestroy->new($$, \&note_unimported, $self);
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
	my @all = ((map { ("+kw:$_", "-kw:$_") } @PublicInbox::LeiInput::KW),
		(map { ("+L:$_", "-L:$_") } @L));
	return @all if !@argv;
	my ($cur, $re) = _complete_mark_common(\@argv);
	map {
		# only return the part specified on the CLI
		# don't duplicate if already 100% completed
		/\A$re(\Q$cur\E.*)/ ? ($cur eq $1 ? () : $1) : ();
	} grep(/$re\Q$cur/, @all);
}

no warnings 'once'; # the following works even when LeiAuth is lazy-loaded
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
