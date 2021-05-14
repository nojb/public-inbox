#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.10.1; use strict; use PublicInbox::TestCommon;
use PublicInbox::DS qw(now);
use File::Path qw(make_path);
use_ok 'PublicInbox::DirIdle';
my ($tmpdir, $for_destroy) = tmpdir();
make_path("$tmpdir/a/b");
my @x;
my $cb = sub { push @x, \@_ };
my $di = PublicInbox::DirIdle->new(["$tmpdir/a"], $cb, 1);
PublicInbox::DS->SetLoopTimeout(1000);
my $end = 3 + now;
PublicInbox::DS->SetPostLoopCallback(sub { scalar(@x) == 0 && now < $end });
tick(0.011);
rmdir("$tmpdir/a/b") or xbail "rmdir $!";
PublicInbox::DS->EventLoop;
is(scalar(@x), 1, 'got an event') and
	is($x[0]->[0]->fullname, "$tmpdir/a/b", 'got expected fullname');
PublicInbox::DS->Reset;
done_testing;
