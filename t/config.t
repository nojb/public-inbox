# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir(CLEANUP => 1);

{
	is(system(qw(git init --bare), $tmpdir), 0, "git init successful");
	{
		local $ENV{GIT_DIR} = $tmpdir;
		is(system(qw(git config foo.bar hihi)), 0, "set config");
	}

	my $tmp = PublicInbox::Config->dump("$tmpdir/config");

	is("hihi", $tmp->{"foo.bar"}, "config read correctly");
	is("true", $tmp->{"core.bare"}, "used --bare repo");
}

done_testing();
