# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# front-end for the "lei index" sub-command, this is similar to
# "lei import" but doesn't put a git blob into ~/.local/share/lei/store
package PublicInbox::LeiIndex;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC PublicInbox::LeiInput);
use PublicInbox::LeiImport;

# /^input_/ subs are used by (or override) PublicInbox::LeiInput superclass
sub input_eml_cb { # used by input_maildir_cb and input_net_cb
	my ($self, $eml, $vmd) = @_;
	my $xoids = $self->{lei}->{ale}->xoids_for($eml);
	if (my $all_vmd = $self->{all_vmd}) {
		@$vmd{keys %$all_vmd} = values %$all_vmd;
	}
	$self->{lei}->{sto}->wq_do('index_eml_only', $eml, $vmd, $xoids);
}

sub input_fh { # overrides PublicInbox::LeiInput::input_fh
	my ($self, $ifmt, $fh, $input, @args) = @_;
	$self->{lei}->child_error(0, <<EOM);
$input ($ifmt) not yet supported, try `lei import'
EOM
}

sub lei_index {
	my ($lei, @argv) = @_;
	$lei->{opt}->{'mail-sync'} = 1;
	my $self = bless {}, __PACKAGE__;
	PublicInbox::LeiImport::do_import_index($self, $lei, @argv);
}

no warnings 'once';
no strict 'refs';
for my $m (qw(pmdir_cb input_net_cb)) {
	*$m = PublicInbox::LeiImport->can($m);
}

*_complete_index = \&PublicInbox::LeiImport::_complete_import;
*ipc_atfork_child = \&PublicInbox::LeiInput::input_only_atfork_child;
*net_merge_all_done = \&PublicInbox::LeiInput::input_only_net_merge_all_done;

1;
