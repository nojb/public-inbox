# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Inbox;
use File::Temp qw/tempdir/;
require './t/common.perl';
require_git(2.6);
my $this = (split('/', __FILE__))[-1];

foreach my $mod (qw(DBD::SQLite)) {
	eval "require $mod";
	plan skip_all => "$mod missing for $this" if $@;
}

my $path = 'blib/script';
my $index = "$path/public-inbox-index";

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
	my $tmpdir = tempdir("pi-$this-tmp-XXXXXX", TMPDIR => 1, CLEANUP => 1);
	my $ibx = PublicInbox::Inbox->new({
		mainrepo => "$tmpdir/testbox",
		name => "$this-$v",
		version => $v,
		-primary_address => 'test@example.com',
		indexlevel => $level,
	});
	my $cls = "PublicInbox::V${v}Writable";
	use_ok $cls;
	my $im = $cls->new($ibx, {nproc=>1});
	$mime->header_set('Message-ID', '<m@1>');
	ok($im->add($mime), 'first message added');
	$im->done;

	# index master (required for v1)
	is(system($index, $ibx->{mainrepo}, "-L$level"), 0, 'index master OK');
	my $ro_master = PublicInbox::Inbox->new({
		mainrepo => $ibx->{mainrepo},
		indexlevel => $level
	});
	my ($nr, $msgs) = $ro_master->recent;
	is($nr, 1, 'only one message in master, so far');
	is($msgs->[0]->{mid}, 'm@1', 'first message in master indexed');

	# clone
	my @cmd = (qw(git clone --mirror -q));
	my $mirror = "$tmpdir/mirror-$v";
	if ($v == 1) {
		push @cmd, $ibx->{mainrepo}, $mirror;
	} else {
		push @cmd, "$ibx->{mainrepo}/git/0.git", "$mirror/git/0.git";
	}
	my $fetch_dir = $cmd[-1];
	is(system(@cmd), 0, "v$v clone OK");

	# inbox init
	local $ENV{PI_CONFIG} = "$tmpdir/.picfg";
	@cmd = ("$path/public-inbox-init", '-L', $level,
		'mirror', $mirror, '//example.com/test', 'test@example.com');
	push @cmd, '-V2' if $v == 2;
	is(system(@cmd), 0, "v$v init OK");

	# index mirror
	is(system($index, $mirror), 0, "v$v index mirror OK");

	# read-only access
	my $ro_mirror = PublicInbox::Inbox->new({
		mainrepo => $mirror,
		indexlevel => 'basic'
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
	is(system($index, $mirror), 0, "v$v index mirror again OK");
	($nr, $msgs) = $ro_mirror->recent;
	is($nr, 2, '2nd message seen in mirror');
	is_deeply([sort { $a cmp $b } map { $_->{mid} } @$msgs],
		['m@1','m@2'], 'got both messages in mirror');

	# incremental index master (required for v1)
	is(system($index, $ibx->{mainrepo}, "-L$level"), 0, 'index master OK');
	($nr, $msgs) = $ro_master->recent;
	is($nr, 2, '2nd message seen in master');
	is_deeply([sort { $a cmp $b } map { $_->{mid} } @$msgs],
		['m@1','m@2'], 'got both messages in master');

	# remove message from master
	ok($im->remove($mime), '2nd message removed');
	$im->done;

	# sync the mirror
	is(system('git', "--git-dir=$fetch_dir", qw(fetch -q)), 0, 'fetch OK');
	is(system($index, $mirror), 0, "v$v index mirror again OK");
	($nr, $msgs) = $ro_mirror->recent;
	is($nr, 1, '2nd message gone from mirror');
	is_deeply([map { $_->{mid} } @$msgs], ['m@1'],
		'message unavailable in mirror');

	if ($v == 2 && $level eq 'basic') {
		is_deeply([glob("$ibx->{mainrepo}/xap*/?/")], [],
			 'no Xapian partition directories for v2 basic');
	}
}

# we can probably cull some other tests and put full/medium tests, here
for my $level (qw(basic)) {
	for my $v (1..2) {
		subtest("v$v indexlevel=$level" => sub {
			import_index_incremental($v, $level);
		})
	}
}

done_testing();
