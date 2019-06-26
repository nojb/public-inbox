# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use warnings;
use Test::More;
use PublicInbox::Syscall qw(:epoll);
my $cls = 'PublicInbox::DSPoll';
use_ok $cls;
my $p = $cls->new;

my ($r, $w, $x, $y);
pipe($r, $w) or die;
pipe($x, $y) or die;
is(epoll_ctl($p, EPOLL_CTL_ADD, fileno($r), EPOLLIN), 0, 'add EPOLLIN');
my $events = [];
my $n = epoll_wait($p, 9, 0, $events);
is_deeply($events, [], 'no events set');
is($n, 0, 'nothing ready, yet');
is(epoll_ctl($p, EPOLL_CTL_ADD, fileno($w), EPOLLOUT|EPOLLONESHOT), 0,
	'add EPOLLOUT|EPOLLONESHOT');
$n = epoll_wait($p, 9, -1, $events);
is($n, 1, 'got POLLOUT event');
is($events->[0]->[0], fileno($w), '$w ready');

$n = epoll_wait($p, 9, 0, $events);
is($n, 0, 'nothing ready after oneshot');
is_deeply($events, [], 'no events set after oneshot');

syswrite($w, '1') == 1 or die;
for my $t (0..1) {
	$n = epoll_wait($p, 9, $t, $events);
	is($events->[0]->[0], fileno($r), "level-trigger POLLIN ready #$t");
	is($n, 1, "only event ready #$t");
}
syswrite($y, '1') == 1 or die;
is(epoll_ctl($p, EPOLL_CTL_ADD, fileno($x), EPOLLIN|EPOLLONESHOT), 0,
	'EPOLLIN|EPOLLONESHOT add');
is(epoll_wait($p, 9, -1, $events), 2, 'epoll_wait has 2 ready');
my @fds = sort(map { $_->[0] } @$events);
my @exp = sort((fileno($r), fileno($x)));
is_deeply(\@fds, \@exp, 'got both ready FDs');

# EPOLL_CTL_DEL doesn't matter for kqueue, we do it in native epoll
# to avoid a kernel-wide lock; but its not needed for native kqueue
# paths so DSKQXS makes it a noop (as did Danga::Socket::close).
SKIP: {
	if ($cls ne 'PublicInbox::DSPoll') {
		skip "$cls doesn't handle EPOLL_CTL_DEL", 2;
	}
	is(epoll_ctl($p, EPOLL_CTL_DEL, fileno($r), 0), 0, 'EPOLL_CTL_DEL OK');
	$n = epoll_wait($p, 9, 0, $events);
	is($n, 0, 'nothing ready after EPOLL_CTL_DEL');
};

done_testing;
