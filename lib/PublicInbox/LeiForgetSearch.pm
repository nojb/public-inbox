# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei forget-search" forget/remove a saved search "lei q --save"
package PublicInbox::LeiForgetSearch;
use strict;
use v5.10.1;
use parent qw(PublicInbox::LeiUp);
use PublicInbox::LeiSavedSearch;
use File::Path ();
use SelectSaver;

sub do_forget_search {
	my ($lei, @outs) = @_;
	my @dirs; # paths in ~/.local/share/lei/saved-search/
	my $cwd;
	for my $o (@outs) {
		my $d = PublicInbox::LeiSavedSearch::lss_dir_for($lei, \$o, 1);
		if (-e $d) {
			push @dirs, $d
		} else { # keep going, like rm(1):
			$cwd //= $lei->rel2abs('.');
			warn "--save was not used with $o cwd=$cwd\n";
		}
	}
	my $save;
	my $opt = { safe => 1 };
	if ($lei->{opt}->{verbose}) {
		$opt->{verbose} = 1;
		$save = SelectSaver->new($lei->{2});
	}
	File::Path::remove_tree(@dirs, $opt);
	$lei->child_error(0) if defined $cwd;
}

sub lei_forget_search {
	my ($lei, @outs) = @_;
	my $prune = $lei->{opt}->{prune};
	$prune // return do_forget_search($lei, @outs);
	return $lei->fail("--prune and @outs incompatible") if @outs;
	my @tmp = PublicInbox::LeiSavedSearch::list($lei);
	my $self = bless { -mail_sync => 1 }, __PACKAGE__;
	$self->filter_lss($lei, $prune) // return
			$lei->fail("only --prune=$prune not understood");
	if ($self->{o_remote}) { # setup lei->{auth}
		$self->prepare_inputs($lei, $self->{o_remote}) or return;
	}
	my $ops = {};
	$lei->{auth}->op_merge($ops, $self, $lei) if $lei->{auth};
	(my $op_c, $ops) = $lei->workers_start($self, 1, $ops);
	$lei->{wq1} = $self;
	net_merge_all_done($self) unless $lei->{auth};
	$lei->wait_wq_events($op_c, $ops);
}

sub do_prune {
	my ($self) = @_;
	my $lei = $self->{lei};
	for my $o (@{$self->{o_local} // []}) {
		next if -e $o;
		$lei->qerr("# pruning $o");
		eval { do_forget_search($lei, $o) };
		$lei->child_error(0, "E: $@") if $@;
	}
	for my $o (@{$self->{o_remote} // []}) {
		my $uri = PublicInbox::URIimap->new($o);
		next if $lei->{net}->mic_for_folder($uri);
		$lei->qerr("# pruning $uri");
		eval { do_forget_search($lei, $o) };
		$lei->child_error(0, "E: $@") if $@;
	}
}

# called in top-level lei-daemon when LeiAuth is done
sub net_merge_all_done {
	my ($self) = @_;
	$self->wq_do('do_prune');
	$self->wq_close;
}

*_wq_done_wait = \&PublicInbox::LEI::wq_done_wait;
*_complete_forget_search = \&PublicInbox::LeiUp::_complete_up;

1;
