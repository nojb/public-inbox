# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei forget-search" forget/remove a saved search "lei q --save"
package PublicInbox::LeiForgetSearch;
use strict;
use v5.10.1;
use PublicInbox::LeiSavedSearch;
use PublicInbox::LeiUp;
use File::Path ();
use SelectSaver;

sub lei_forget_search {
	my ($lei, $out) = @_;
	my $d = PublicInbox::LeiSavedSearch::lss_dir_for($lei, \$out, 1);
	if (-e $d) {
		my $save;
		my $opt = { safe => 1 };
		if ($lei->{opt}->{verbose}) {
			$opt->{verbose} = 1;
			$save = SelectSaver->new($lei->{2});
		}
		File::Path::remove_tree($d, $opt);
	} else {
		$lei->fail("--save was not used with $out cwd=".
					$lei->rel2abs('.'));
	}
}

*_complete_forget_search = \&PublicInbox::LeiUp::_complete_up;

1;
