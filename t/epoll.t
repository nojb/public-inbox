use strict;
use Test::More;
use IO::Handle;
use PublicInbox::Syscall qw(:epoll);
plan skip_all => 'not Linux' if $^O ne 'linux';
my $epfd = epoll_create();
ok($epfd >= 0, 'epoll_create');
my $hnd = IO::Handle->new_from_fd($epfd, 'r+'); # close on exit

pipe(my ($r, $w)) or die "pipe: $!";
is(epoll_ctl($epfd, EPOLL_CTL_ADD, fileno($w), EPOLLOUT), 0,
    'epoll_ctl socket EPOLLOUT');

my @events;
is(epoll_wait($epfd, 100, 10000, \@events), 1, 'epoll_wait returns');
is_deeply(\@events, [ [ fileno($w), EPOLLOUT ] ], 'got expected events');
close $w;
is(epoll_wait($epfd, 100, 0, \@events), 0, 'epoll_wait timeout');

done_testing;
