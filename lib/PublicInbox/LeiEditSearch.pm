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
	if ($lei->{oneshot}) {
		exec(@cmd) or die "exec @cmd: $!\n";
	} else {
		$lei->send_exec_cmd([], \@cmd, {});
	}
}

*_complete_edit_search = \&PublicInbox::LeiUp::_complete_up;

1;
