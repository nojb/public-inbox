# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# real-world testing of search threading
use strict;
use warnings;
use Test::More;
use Benchmark qw(:all);
use PublicInbox::Inbox;
my $pi_dir = $ENV{GIANT_PI_DIR};
plan skip_all => "GIANT_PI_DIR not defined for $0" unless $pi_dir;
my $ibx = PublicInbox::Inbox->new({ mainrepo => $pi_dir });
eval { require PublicInbox::Search };
my $srch = $ibx->search;
plan skip_all => "$pi_dir not configured for search $0 $@" unless $srch;

require PublicInbox::View;

my $msgs;
my $elapsed = timeit(1, sub {
	$msgs = $srch->{over_ro}->recent({limit => 200000});
});
my $n = scalar(@$msgs);
ok($n, 'got some messages');
diag "enquire: ".timestr($elapsed)." for $n";

$elapsed = timeit(1, sub {
	PublicInbox::View::thread_results({-inbox => $ibx}, $msgs);
});
diag "thread_results ".timestr($elapsed);

done_testing();
