#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.10.1; use strict; use PublicInbox::TestCommon;
use PublicInbox::DS qw(now);
use File::Path qw(make_path);
use_ok 'PublicInbox::DirIdle';
my ($tmpdir, $for_destroy) = tmpdir();
make_path("$tmpdir/a/b", "$tmpdir/c");
my @x;
my $cb = sub { push @x, \@_ };
my $di = PublicInbox::DirIdle->new($cb);
$di->add_watches(["$tmpdir/a", "$tmpdir/c"], 1);
PublicInbox::DS->SetLoopTimeout(1000);
my $end = 3 + now;
PublicInbox::DS->SetPostLoopCallback(sub { scalar(@x) == 0 && now < $end });
tick(0.011);
rmdir("$tmpdir/a/b") or xbail "rmdir $!";
PublicInbox::DS::event_loop();
is(scalar(@x), 1, 'got an event') and
	is($x[0]->[0]->fullname, "$tmpdir/a/b", 'got expected fullname') and
	ok($x[0]->[0]->IN_DELETE, 'IN_DELETE set');

tick(0.011);
rmdir("$tmpdir/a") or xbail "rmdir $!";
@x = ();
$end = 3 + now;
PublicInbox::DS::event_loop();
is(scalar(@x), 1, 'got an event') and
	is($x[0]->[0]->fullname, "$tmpdir/a", 'got expected fullname') and
	ok($x[0]->[0]->IN_DELETE_SELF, 'IN_DELETE_SELF set');

tick(0.011);
rename("$tmpdir/c", "$tmpdir/j") or xbail "rmdir $!";
@x = ();
$end = 3 + now;
PublicInbox::DS::event_loop();
is(scalar(@x), 1, 'got an event') and
	is($x[0]->[0]->fullname, "$tmpdir/c", 'got expected fullname') and
	ok($x[0]->[0]->IN_DELETE_SELF || $x[0]->[0]->IN_MOVE_SELF,
		'IN_DELETE_SELF set on move');

PublicInbox::DS->Reset;
done_testing;
