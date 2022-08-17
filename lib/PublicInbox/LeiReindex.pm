# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei reindex" command to reindex everything in lei/store
package PublicInbox::LeiReindex;
use v5.12;
use parent qw(PublicInbox::IPC);

sub reindex_full {
	my ($lei) = @_;
	my $sto = $lei->{sto};
	my $max = $sto->search->over(1)->max;
	$lei->qerr("# reindexing 1..$max");
	$sto->wq_do('reindex_art', $_) for (1..$max);
}

sub reindex_store { # via wq_do
	my ($self) = @_;
	my ($lei, $argv) = delete @$self{qw(lei argv)};
	if (!@$argv) {
		reindex_full($lei);
	}
}

sub lei_reindex {
	my ($lei, @argv) = @_;
	my $sto = $lei->_lei_store or return $lei->fail('nothing indexed');
	$sto->write_prepare($lei);
	my $self = bless { lei => $lei, argv => \@argv }, __PACKAGE__;
	my ($op_c, $ops) = $lei->workers_start($self, 1);
	$lei->{wq1} = $self;
	$lei->wait_wq_events($op_c, $ops);
	$self->wq_do('reindex_store');
	$self->wq_close;
}

sub _lei_wq_eof { # EOF callback for main lei daemon
	my ($lei) = @_;
	$lei->{sto}->wq_do('reindex_done');
	$lei->wq_eof;
}

sub ipc_atfork_child {
	my ($self) = @_;
	$self->{lei}->_lei_atfork_child;
	$self->SUPER::ipc_atfork_child;
}

1;
