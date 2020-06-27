#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Ensure FakeInotify can pick up rename(2) and link(2) operations
# used by Maildir writing tools
use strict;
use Test::More;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::FakeInotify';
my $MIN_FS_TICK = 0.011; # for low-res CONFIG_HZ=100 systems
my ($tmpdir, $for_destroy) = tmpdir();
mkdir "$tmpdir/new" or BAIL_OUT "mkdir: $!";
open my $fh, '>', "$tmpdir/tst" or BAIL_OUT "open: $!";
close $fh or BAIL_OUT "close: $!";

my $fi = PublicInbox::FakeInotify->new;
my $mask = PublicInbox::FakeInotify::MOVED_TO_OR_CREATE();
my $hit = [];
my $cb = sub { push @$hit, map { $_->fullname } @_ };
my $w = $fi->watch("$tmpdir/new", $mask, $cb);

select undef, undef, undef, $MIN_FS_TICK;
rename("$tmpdir/tst", "$tmpdir/new/tst") or BAIL_OUT "rename: $!";
$fi->poll;
is_deeply($hit, ["$tmpdir/new/tst"], 'rename(2) detected');

@$hit = ();
select undef, undef, undef, $MIN_FS_TICK;
open $fh, '>', "$tmpdir/tst" or BAIL_OUT "open: $!";
close $fh or BAIL_OUT "close: $!";
link("$tmpdir/tst", "$tmpdir/new/link") or BAIL_OUT "link: $!";
$fi->poll;
is_deeply($hit, ["$tmpdir/new/link"], 'link(2) detected');

$w->cancel;
@$hit = ();
select undef, undef, undef, $MIN_FS_TICK;
link("$tmpdir/new/tst", "$tmpdir/new/link2") or BAIL_OUT "link: $!";
$fi->poll;
is_deeply($hit, [], 'link(2) not detected after cancel');

PublicInbox::DS->Reset;

done_testing;
