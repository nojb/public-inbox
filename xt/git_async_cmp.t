#!perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use Benchmark qw(:all);
use Digest::SHA;
use PublicInbox::TestCommon;
my $git_dir = $ENV{GIANT_GIT_DIR};
plan 'skip_all' => "GIANT_GIT_DIR not defined for $0" unless defined($git_dir);
use_ok 'PublicInbox::Git';
my $git = PublicInbox::Git->new($git_dir);
my @cat = qw(cat-file --buffer --batch-check --batch-all-objects);
if (require_git(2.19, 1)) {
	push @cat, '--unordered';
} else {
	warn "git <2.19, cat-file lacks --unordered, locality suffers\n";
}
my @dig;
my $nr = $ENV{NR} || 1;
diag "NR=$nr";
my $async = timeit($nr, sub {
	my $dig = Digest::SHA->new(1);
	my $cb = sub {
		my ($bref) = @_;
		$dig->add($$bref);
	};
	my $cat = $git->popen(@cat);

	while (<$cat>) {
		my ($oid, undef, undef) = split(/ /);
		$git->cat_async($oid, $cb);
	}
	close $cat or die "cat: $?";
	$git->async_wait_all;
	push @dig, ['async', $dig->hexdigest ];
});

my $sync = timeit($nr, sub {
	my $dig = Digest::SHA->new(1);
	my $cat = $git->popen(@cat);
	while (<$cat>) {
		my ($oid, undef, undef) = split(/ /);
		my $bref = $git->cat_file($oid);
		$dig->add($$bref);
	}
	close $cat or die "cat: $?";
	push @dig, ['sync', $dig->hexdigest ];
});

ok(scalar(@dig) >= 2, 'got some digests');
my $ref = shift @dig;
my $exp = $ref->[1];
isnt($exp, Digest::SHA->new(1)->hexdigest, 'not empty');
foreach (@dig) {
	is($_->[1], $exp, "digest matches $_->[0] <=> $ref->[0]");
}
diag "sync=".timestr($sync);
diag "async=".timestr($async);
done_testing;
1;
