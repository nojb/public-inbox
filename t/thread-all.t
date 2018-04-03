# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# real-world testing of search threading
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use PublicInbox::Inbox;
my $pi_dir = $ENV{GIANT_PI_DIR};
plan skip_all => "GIANT_PI_DIR not defined for $0" unless $pi_dir;
my $ibx = PublicInbox::Inbox->new({ mainrepo => $pi_dir });
my $srch = $ibx->search;
plan skip_all => "$pi_dir not configured for search $0" unless $srch;

require PublicInbox::View;
require PublicInbox::SearchThread;

my $t0 = clock_gettime(CLOCK_MONOTONIC);
my $elapsed;
my $msgs = $srch->{over_ro}->recent({limit => 200000});
my $n =	scalar(@$msgs);
ok($n, 'got some messages');
$elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
diag "enquire: $elapsed for $n";

$t0 = clock_gettime(CLOCK_MONOTONIC);
PublicInbox::View::thread_results({-inbox => $ibx}, $msgs);
$elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
diag "thread_results $elapsed";

done_testing();
