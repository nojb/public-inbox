# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir(CLEANUP => 1);
use constant pi_init => 'blib/script/public-inbox-init';

{
	local $ENV{PI_DIR} = "$tmpdir/.public-inbox/";
	my $cfgfile = "$ENV{PI_DIR}/config";
	my @cmd = (pi_init, 'blist', "$tmpdir/blist",
		   qw(http://example.com/blist blist@example.com));
	is(system(@cmd), 0, 'public-inbox-init failed');

	ok(-e $cfgfile, "config exists, now");
	is(system(@cmd), 0, 'public-inbox-init failed (idempotent)');
}

done_testing();
