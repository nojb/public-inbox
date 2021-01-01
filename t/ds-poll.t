# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use warnings;
use Test::More;
use PublicInbox::Syscall qw(:epoll);
my $cls = $ENV{TEST_IOPOLLER} // 'PublicInbox::DSPoll';
use_ok $cls;
my $p = $cls->new;

my ($r, $w, $x, $y);
pipe($r, $w) or die;
pipe($x, $y) or die;
is($p->epoll_ctl(EPOLL_CTL_ADD, fileno($r), EPOLLIN), 0, 'add EPOLLIN');
my $events = [];
$p->epoll_wait(9, 0, $events);
is_deeply($events, [], 'no events set');
is($p->epoll_ctl(EPOLL_CTL_ADD, fileno($w), EPOLLOUT|EPOLLONESHOT), 0,
	'add EPOLLOUT|EPOLLONESHOT');
$p->epoll_wait(9, -1, $events);
is(scalar(@$events), 1, 'got POLLOUT event');
is($events->[0], fileno($w), '$w ready');

$p->epoll_wait(9, 0, $events);
is(scalar(@$events), 0, 'nothing ready after oneshot');
is_deeply($events, [], 'no events set after oneshot');

syswrite($w, '1') == 1 or die;
for my $t (0..1) {
	$p->epoll_wait(9, $t, $events);
	is($events->[0], fileno($r), "level-trigger POLLIN ready #$t");
	is(scalar(@$events), 1, "only event ready #$t");
}
syswrite($y, '1') == 1 or die;
is($p->epoll_ctl(EPOLL_CTL_ADD, fileno($x), EPOLLIN|EPOLLONESHOT), 0,
	'EPOLLIN|EPOLLONESHOT add');
$p->epoll_wait(9, -1, $events);
is(scalar @$events, 2, 'epoll_wait has 2 ready');
my @fds = sort @$events;
my @exp = sort((fileno($r), fileno($x)));
is_deeply(\@fds, \@exp, 'got both ready FDs');

is($p->epoll_ctl(EPOLL_CTL_DEL, fileno($r), 0), 0, 'EPOLL_CTL_DEL OK');
$p->epoll_wait(9, 0, $events);
is(scalar @$events, 0, 'nothing ready after EPOLL_CTL_DEL');

done_testing;
