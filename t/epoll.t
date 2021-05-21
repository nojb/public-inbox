#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::Syscall qw(:epoll);
plan skip_all => 'not Linux' if $^O ne 'linux';
my $epfd = epoll_create();
ok($epfd >= 0, 'epoll_create');
open(my $hnd, '+<&=', $epfd); # for autoclose

pipe(my ($r, $w)) or die "pipe: $!";
is(epoll_ctl($epfd, EPOLL_CTL_ADD, fileno($w), EPOLLOUT), 0,
    'epoll_ctl socket EPOLLOUT');

my @events;
epoll_wait($epfd, 100, 10000, \@events);
is(scalar(@events), 1, 'got one event');
is($events[0], fileno($w), 'got expected FD');
close $w;
epoll_wait($epfd, 100, 0, \@events);
is(scalar(@events), 0, 'epoll_wait timeout');

done_testing;
