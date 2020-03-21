# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use IO::Handle (); # autoflush
use Fcntl qw(SEEK_SET);
use PublicInbox::TestCommon;
require_mods(qw(Compress::Zlib IO::Uncompress::Gunzip));
require_ok 'PublicInbox::GzipFilter';

{
	open my $fh, '+>', undef or die "open: $!";
	open my $dup, '>&', $fh or die "dup $!";
	$dup->autoflush(1);
	my $filter = PublicInbox::GzipFilter->new->attach($dup);
	ok($filter->write("hello"), 'wrote something');
	ok($filter->write("world"), 'wrote more');
	$filter->close;
	seek($fh, 0, SEEK_SET) or die;
	IO::Uncompress::Gunzip::gunzip($fh => \(my $buf));
	is($buf, 'helloworld', 'buffer matches');
}

{
	pipe(my ($r, $w)) or die "pipe: $!";
	$w->autoflush(1);
	close $r or die;
	my $filter = PublicInbox::GzipFilter->new->attach($w);
	my $sigpipe;
	local $SIG{PIPE} = sub { $sigpipe = 1 };
	open my $fh, '<', 'COPYING' or die "open(COPYING): $!";
	my $buf = do { local $/; <$fh> };
	while ($filter->write($buf .= rand)) {}
	ok($sigpipe, 'got SIGPIPE');
	close $w;
}
done_testing;
