# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir('emergency-XXXXXX', TMPDIR => 1, CLEANUP => 1);
use_ok 'PublicInbox::Emergency';

{
	my $md = "$tmpdir/a";
	my $em = PublicInbox::Emergency->new($md);
	ok(-d $md, 'Maildir a auto-created');
	my @tmp = <$md/tmp/*>;
	is(scalar @tmp, 0, 'no temporary files exist, yet');
	$em->prepare(\"BLAH");
	@tmp = <$md/tmp/*>;
	is(scalar @tmp, 1, 'globbed one temporary file');
	open my $fh, '<', $tmp[0] or die "failed to open: $!";
	is("BLAH", <$fh>, 'wrote contents to temporary location');
	my @new = <$md/new/*>;
	is(scalar @new, 0, 'no new files exist, yet');
	$em = undef;
	@tmp = <$md/tmp/*>;
	is(scalar @tmp, 0, 'temporary file no longer exists');
	@new = <$md/new/*>;
	is(scalar @new, 1, 'globbed one new file');
	open $fh, '<', $new[0] or die "failed to open: $!";
	is("BLAH", <$fh>, 'wrote contents to new location');
}
{
	my $md = "$tmpdir/b";
	my $em = PublicInbox::Emergency->new($md);
	ok(-d $md, 'Maildir b auto-created');
	my @tmp = <$md/tmp/*>;
	is(scalar @tmp, 0, 'no temporary files exist, yet');
	$em->prepare(\"BLAH");
	@tmp = <$md/tmp/*>;
	is(scalar @tmp, 1, 'globbed one temporary file');
	open my $fh, '<', $tmp[0] or die "failed to open: $!";
	is("BLAH", <$fh>, 'wrote contents to temporary location');
	my @new = <$md/new/*>;
	is(scalar @new, 0, 'no new files exist, yet');
	is(sysread($em->fh, my $buf, 9), 4, 'read file handle exposed');
	is($buf, 'BLAH', 'got expected data');
	$em->abort;
	@tmp = <$md/tmp/*>;
	is(scalar @tmp, 0, 'temporary file no longer exists');
	@new = <$md/new/*>;
	is(scalar @new , 0, 'new file no longer exists');
}

done_testing();
