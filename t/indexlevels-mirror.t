# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Inbox;
use PublicInbox::InboxWritable;
use File::Temp qw/tempdir/;
require PublicInbox::Admin;
require './t/common.perl';
my $PI_TEST_VERSION = $ENV{PI_TEST_VERSION} || 2;
require_git('2.6') if $PI_TEST_VERSION == 2;

foreach my $mod (qw(DBD::SQLite)) {
	eval "require $mod";
	plan skip_all => "$mod missing for $0" if $@;
}

my @xcpdb = qw(-xcpdb -q);

my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);

sub import_index_incremental {
	my ($v, $level) = @_;
	my $this = "pi-$v-$level-indexlevels";
	my $tmpdir = tempdir("$this-tmp-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	my $ibx = PublicInbox::Inbox->new({
		inboxdir => "$tmpdir/testbox",
		name => $this,
		version => $v,
		-primary_address => 'test@example.com',
		indexlevel => $level,
	});
	my $im = PublicInbox::InboxWritable->new($ibx, {nproc=>1})->importer;
	$mime->header_set('Message-ID', '<m@1>');
	ok($im->add($mime), 'first message added');
	$im->done;

	# index master (required for v1)
	ok(run_script(['-index', $ibx->{inboxdir}, "-L$level"]),
		'index master OK');
	my $ro_master = PublicInbox::Inbox->new({
		inboxdir => $ibx->{inboxdir},
		indexlevel => $level
	});
	my ($nr, $msgs) = $ro_master->recent;
	is($nr, 1, 'only one message in master, so far');
	is($msgs->[0]->{mid}, 'm@1', 'first message in master indexed');

	# clone
	my @cmd = (qw(git clone --mirror -q));
	my $mirror = "$tmpdir/mirror-$v";
	if ($v == 1) {
		push @cmd, $ibx->{inboxdir}, $mirror;
	} else {
		push @cmd, "$ibx->{inboxdir}/git/0.git", "$mirror/git/0.git";
	}
	my $fetch_dir = $cmd[-1];
	is(system(@cmd), 0, "v$v clone OK");

	# inbox init
	local $ENV{PI_CONFIG} = "$tmpdir/.picfg";
	@cmd = ('-init', '-L', $level,
		'mirror', $mirror, '//example.com/test', 'test@example.com');
	push @cmd, '-V2' if $v == 2;
	ok(run_script(\@cmd), "v$v init OK");

	# index mirror
	ok(run_script(['-index', $mirror]), "v$v index mirror OK");

	# read-only access
	my $ro_mirror = PublicInbox::Inbox->new({
		inboxdir => $mirror,
		indexlevel => $level,
	});
	($nr, $msgs) = $ro_mirror->recent;
	is($nr, 1, 'only one message, so far');
	is($msgs->[0]->{mid}, 'm@1', 'read first message');

	# update master
	$mime->header_set('Message-ID', '<m@2>');
	ok($im->add($mime), '2nd message added');
	$im->done;

	# mirror updates
	is(system('git', "--git-dir=$fetch_dir", qw(fetch -q)), 0, 'fetch OK');
	ok(run_script(['-index', $mirror]), "v$v index mirror again OK");
	($nr, $msgs) = $ro_mirror->recent;
	is($nr, 2, '2nd message seen in mirror');
	is_deeply([sort { $a cmp $b } map { $_->{mid} } @$msgs],
		['m@1','m@2'], 'got both messages in mirror');

	# incremental index master (required for v1)
	ok(run_script(['-index', $ibx->{inboxdir}, "-L$level"]),
		'index master OK');
	($nr, $msgs) = $ro_master->recent;
	is($nr, 2, '2nd message seen in master');
	is_deeply([sort { $a cmp $b } map { $_->{mid} } @$msgs],
		['m@1','m@2'], 'got both messages in master');

	my @rw_nums = map { $_->{num} } @{$ibx->over->query_ts(0, 0)};
	is_deeply(\@rw_nums, [1, 2], 'master has expected NNTP articles');

	my @ro_nums = map { $_->{num} } @{$ro_mirror->over->query_ts(0, 0)};
	is_deeply(\@ro_nums, [1, 2], 'mirror has expected NNTP articles');

	# remove message from master
	ok($im->remove($mime), '2nd message removed');
	$im->done;
	@rw_nums = map { $_->{num} } @{$ibx->over->query_ts(0, 0)};
	is_deeply(\@rw_nums, [1], 'unindex NNTP article'.$v.$level);

	if ($level ne 'basic') {
		ok(run_script([@xcpdb, $mirror]), "v$v xcpdb OK");
		is(PublicInbox::Admin::detect_indexlevel($ro_mirror), $level,
		   'indexlevel detectable by Admin after xcpdb v' .$v.$level);
		delete $ro_mirror->{$_} for (qw(over search));
		($nr, $msgs) = $ro_mirror->search->query('m:m@2');
		is($nr, 1, "v$v found m\@2 via Xapian on $level");
	}

	# sync the mirror
	is(system('git', "--git-dir=$fetch_dir", qw(fetch -q)), 0, 'fetch OK');
	ok(run_script(['-index', $mirror]), "v$v index mirror again OK");
	($nr, $msgs) = $ro_mirror->recent;
	is($nr, 1, '2nd message gone from mirror');
	is_deeply([map { $_->{mid} } @$msgs], ['m@1'],
		'message unavailable in mirror');

	if ($v == 2 && $level eq 'basic') {
		is_deeply([glob("$ibx->{inboxdir}/xap*/?/")], [],
			 'no Xapian shard directories for v2 basic');
	}
	if ($level ne 'basic') {
		($nr, $msgs) = $ro_mirror->search->reopen->query('m:m@2');
		is($nr, 0, "v$v m\@2 gone from Xapian in mirror on $level");
	}

	# add another message to master and have the mirror
	# sync and reindex it
	my @expect = map { $_->{num} } @{$ibx->over->query_ts(0, 0)};
	foreach my $i (3..5) {
		$mime->header_set('Message-ID', "<m\@$i>");
		ok($im->add($mime), "#$i message added");
		push @expect, $i;
	}
	$im->done;
	is(system('git', "--git-dir=$fetch_dir", qw(fetch -q)), 0, 'fetch OK');
	ok(run_script(['-index', '--reindex', $mirror]),
		"v$v index --reindex mirror OK");
	@ro_nums = map { $_->{num} } @{$ro_mirror->over->query_ts(0, 0)};
	@rw_nums = map { $_->{num} } @{$ibx->over->query_ts(0, 0)};
	is_deeply(\@rw_nums, \@expect, "v$v master has expected NNTP articles");
	is_deeply(\@ro_nums, \@expect, "v$v mirror matches master articles");

	is(PublicInbox::Admin::detect_indexlevel($ro_mirror), $level,
	   'indexlevel detectable by Admin '.$v.$level);
}

# we can probably cull some other tests
import_index_incremental($PI_TEST_VERSION, 'basic');

SKIP: {
	require PublicInbox::Search;
	PublicInbox::Search::load_xapian() or skip 'Search::Xapian missing', 2;
	foreach my $l (qw(medium full)) {
		import_index_incremental($PI_TEST_VERSION, $l);
	}
}

done_testing();
