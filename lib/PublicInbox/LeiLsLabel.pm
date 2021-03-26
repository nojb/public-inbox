# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei ls-label" command
package PublicInbox::LeiLsLabel;
use strict;
use v5.10.1;

sub lei_ls_label { # the "lei ls-label" method
	my ($lei, @argv) = @_;
	# TODO: document stats/counts (expensive)
	my @L = eval { $lei->_lei_store->search->all_terms('L') };
	my $ORS = $lei->{opt}->{z} ? "\0" : "\n";
	$lei->out(map { $_.$ORS } @L);
}

1;
