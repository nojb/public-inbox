# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# real-world testing of search threading
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my $pi_dir = $ENV{GIANT_PI_DIR};
plan skip_all => "GIANT_PI_DIR not defined for $0" unless $pi_dir;
eval { require PublicInbox::Search; };
plan skip_all => "Xapian missing for $0" if $@;
my $srch = eval { PublicInbox::Search->new($pi_dir) };
plan skip_all => "$pi_dir not initialized for $0" if $@;

require PublicInbox::View;
require PublicInbox::SearchThread;

my $pfx = PublicInbox::Search::xpfx('thread');
my $opts = { limit => 1000000, asc => 1 };
my $t0 = clock_gettime(CLOCK_MONOTONIC);
my $elapsed;

my $sres = $srch->_do_enquire(undef, $opts);
$elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
diag "enquire: $elapsed";

$t0 = clock_gettime(CLOCK_MONOTONIC);
my $msgs = PublicInbox::View::load_results($srch, $sres);
$elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
diag "load_results $elapsed";

$t0 = clock_gettime(CLOCK_MONOTONIC);
PublicInbox::View::thread_results($msgs);
$elapsed = clock_gettime(CLOCK_MONOTONIC) - $t0;
diag "thread_results $elapsed";

done_testing();
