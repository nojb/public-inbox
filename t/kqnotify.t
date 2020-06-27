#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Ensure KQNotify can pick up rename(2) and link(2) operations
# used by Maildir writing tools
use strict;
use Test::More;
use PublicInbox::TestCommon;
plan skip_all => 'KQNotify is only for *BSD systems' if $^O !~ /bsd/;
require_mods('IO::KQueue');
use_ok 'PublicInbox::KQNotify';
my ($tmpdir, $for_destroy) = tmpdir();
mkdir "$tmpdir/new" or BAIL_OUT "mkdir: $!";
open my $fh, '>', "$tmpdir/tst" or BAIL_OUT "open: $!";
close $fh or BAIL_OUT "close: $!";

my $kqn = PublicInbox::KQNotify->new;
my $mask = PublicInbox::KQNotify::MOVED_TO_OR_CREATE();
my $hit = [];
my $cb = sub { push @$hit, map { $_->fullname } @_ };
my $w = $kqn->watch("$tmpdir/new", $mask, $cb);

rename("$tmpdir/tst", "$tmpdir/new/tst") or BAIL_OUT "rename: $!";
$kqn->poll;
is_deeply($hit, ["$tmpdir/new/tst"], 'rename(2) detected (via NOTE_EXTEND)');

@$hit = ();
open $fh, '>', "$tmpdir/tst" or BAIL_OUT "open: $!";
close $fh or BAIL_OUT "close: $!";
link("$tmpdir/tst", "$tmpdir/new/link") or BAIL_OUT "link: $!";
$kqn->poll;
is_deeply($hit, ["$tmpdir/new/link"], 'link(2) detected (via NOTE_WRITE)');

$w->cancel;
@$hit = ();
link("$tmpdir/new/tst", "$tmpdir/new/link2") or BAIL_OUT "link: $!";
$kqn->poll;
is_deeply($hit, [], 'link(2) not detected after cancel');

done_testing;
