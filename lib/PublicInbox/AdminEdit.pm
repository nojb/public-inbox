# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# common stuff between -edit, -purge (and maybe -learn in the future)
package PublicInbox::AdminEdit;
use strict;
use warnings;
use PublicInbox::Admin;
our @OPT = qw(all force|f verbose|v! help|h);

sub check_editable ($) {
	my ($ibxs) = @_;

	foreach my $ibx (@$ibxs) {
		my $lvl = $ibx->{indexlevel};
		if (defined $lvl) {
			PublicInbox::Admin::indexlevel_ok_or_die($lvl);
			next;
		}

		# Undefined indexlevel, so `full'...
		# Search::Xapian exists and the DB can be read, at least, fine
		$ibx->search and next;

		# it's possible for a Xapian directory to exist,
		# but Search::Xapian to go missing/broken.
		# Make sure it's purged in that case:
		$ibx->over or die "no over.sqlite3 in $ibx->{inboxdir}\n";

		require PublicInbox::Search;
		my $xdir_ro = PublicInbox::Search->new($ibx)->xdir(1);

		my $nshard = 0;
		foreach my $shard (<$xdir_ro/*>) {
			if (-d $shard && $shard =~ m!/[0-9]+\z!) {
				my $bytes = 0;
				$bytes += -s $_ foreach glob("$shard/*");
				$nshard++ if $bytes;
			}
		}
		if ($nshard) {
			PublicInbox::Admin::require_or_die('-search');
		} else {
			# somebody could "rm -r" all the Xapian directories;
			# let them purge the overview, at least
			$ibx->{indexlevel} ||= 'basic';
		}
	}
}

# takes the output of V2Writable::purge and V2Writable::replace
# $rewrites = [ array commits keyed by epoch ]
sub show_rewrites ($$$) {
	my ($fh, $ibx, $rewrites) = @_;
	print $fh "$ibx->{inboxdir}:";
	if (scalar @$rewrites) {
		my $epoch = -1;
		my @out = map {;
			++$epoch;
			"$epoch.git: ".(defined($_) ? $_ : '(unchanged)')
		} @$rewrites;
		print $fh join("\n\t", '', @out), "\n";
	} else {
		print $fh " NONE\n";
	}
}

1;
