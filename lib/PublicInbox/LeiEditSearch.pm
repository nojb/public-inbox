# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei edit-search" edit a saved search following "lei q --save"
package PublicInbox::LeiEditSearch;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use PublicInbox::LeiUp;

sub lei_edit_search {
	my ($lei, $out) = @_;
	my $lss = PublicInbox::LeiSavedSearch->up($lei, $out) or return;
	my @cmd = (qw(git config --edit -f), $lss->{'-f'});
	$lei->qerr("# spawning @cmd");
	$lss->edit_begin($lei);
	# run in script/lei foreground
	require PublicInbox::PktOp;
	my ($op_c, $op_p) = PublicInbox::PktOp->pair;
	# $op_p will EOF when $EDITOR is done
	$op_c->{ops} = { '' => [$lss->can('edit_done'), $lss, $lei] };
	$lei->send_exec_cmd([ @$lei{qw(0 1 2)}, $op_p ], \@cmd, {});
}

*_complete_edit_search = \&PublicInbox::LeiUp::_complete_up;

1;
