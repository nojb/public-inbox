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
	$lei->fail if defined $cwd;
}

*_complete_forget_search = \&PublicInbox::LeiUp::_complete_up;

1;
