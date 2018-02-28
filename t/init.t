# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir('pi-init-XXXXXX', TMPDIR => 1, CLEANUP => 1);
use constant pi_init => 'blib/script/public-inbox-init';

{
	local $ENV{PI_DIR} = "$tmpdir/.public-inbox/";
	my $cfgfile = "$ENV{PI_DIR}/config";
	my @cmd = (pi_init, 'blist', "$tmpdir/blist",
		   qw(http://example.com/blist blist@example.com));
	is(system(@cmd), 0, 'public-inbox-init OK');

	ok(-e $cfgfile, "config exists, now");
	is(system(@cmd), 0, 'public-inbox-init OK (idempotent)');

	chmod 0666, $cfgfile or die "chmod failed: $!";
	@cmd = (pi_init, 'clist', "$tmpdir/clist",
		   qw(http://example.com/clist clist@example.com));
	is(system(@cmd), 0, 'public-inbox-init clist OK');
	is((stat($cfgfile))[2] & 07777, 0666, "permissions preserved");
}

SKIP: {
	foreach my $mod (qw(DBD::SQLite Search::Xapian::WritableDatabase)) {
		eval "require $mod";
		skip "$mod missing for v2", 2 if $@;
	}
	local $ENV{PI_DIR} = "$tmpdir/.public-inbox/";
	my $cfgfile = "$ENV{PI_DIR}/config";
	my @cmd = (pi_init, '-V2', 'v2list', "$tmpdir/v2list",
		   qw(http://example.com/v2list v2list@example.com));
	is(system(@cmd), 0, 'public-inbox-init -V2 OK');
	ok(-d "$tmpdir/v2list", 'v2list directory exists');
	ok(-f "$tmpdir/v2list/msgmap.sqlite3", 'msgmap exists');
	ok(-d "$tmpdir/v2list/all.git", 'catch-all.git directory exists');
}

done_testing();
