# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use Benchmark qw(:all);
use PublicInbox::TestCommon;
require_ok 'PublicInbox::SharedKV';
my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{TMPDIR} = $tmpdir;
my $skv = PublicInbox::SharedKV->new;
my $ipc = bless {}, 'StressSharedKV';
$ipc->wq_workers_start('stress-sharedkv', $ENV{TEST_NPROC}//4);
my $nr = $ENV{TEST_STRESS_NR} // 100_000;
my $ios = [];
my $t = timeit(1, sub {
	for my $i (1..$nr) {
		$ipc->wq_io_do('test_set_maybe', $ios, $skv, $i);
		$ipc->wq_io_do('test_set_maybe', $ios, $skv, $i);
	}
});
diag "$nr sets done ".timestr($t);

for my $w ($ipc->wq_workers) {
	$ipc->wq_io_do('test_skv_done', $ios);
}
diag "done requested";

$ipc->wq_close;
done_testing;

package StressSharedKV;
use strict;
use v5.10.1;
use parent qw(PublicInbox::IPC);
use Digest::SHA qw(sha1);

sub test_set_maybe {
	my ($self, $skv, $i) = @_;
	my $wcb = $self->{wcb} //= do {
		$skv->dbh;
		sub { $skv->set_maybe(sha1($_[0]), '') };
	};
	$wcb->($i + time);
}

sub test_skv_done {
	my ($self) = @_;
	delete $self->{wcb};
}
