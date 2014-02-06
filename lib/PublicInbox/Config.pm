# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Config;

# returns key-value pairs of config directives in a hash
sub dump {
	my ($class, $file) = @_;

	local $ENV{GIT_CONFIG} = $file;

	my @cfg = `git config -l`;
	$? == 0 or die "git config -l failed: $?\n";
	chomp @cfg;
	my %rv = map { split(/=/, $_, 2) } @cfg;
	\%rv;
}

1;
