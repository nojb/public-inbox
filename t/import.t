# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::Spawn qw(spawn);
use IO::File;
use Fcntl qw(:DEFAULT);
use File::Temp qw/tempdir tempfile/;
my $dir = tempdir('pi-import-XXXXXX', TMPDIR => 1, CLEANUP => 1);

is(system(qw(git init -q --bare), $dir), 0, 'git init successful');
my $git = PublicInbox::Git->new($dir);

my $im = PublicInbox::Import->new($git, 'testbox', 'test@example');
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'b@example.com',
		'Content-Type' => 'text/plain',
		Subject => 'this is a subject',
		'Message-ID' => '<a@example.com>',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);

$im->{want_object_info} = 1 if 'v2';
like($im->add($mime), qr/\A:\d+\z/, 'added one message');

if ('v2') {
	my $info = $im->{last_object};
	like($info->[0], qr/\A[a-f0-9]{40}\z/, 'got last object_id');
	is($mime->as_string, ${$info->[2]}, 'string matches');
	is($info->[1], length(${$info->[2]}), 'length matches');
	my @cmd = ('git', "--git-dir=$git->{git_dir}", qw(hash-object --stdin));
	my $in = tempfile();
	print $in $mime->as_string or die "write failed: $!";
	$in->flush or die "flush failed: $!";
	$in->seek(0, SEEK_SET);
	my $out = tempfile();
	my $pid = spawn(\@cmd, {}, { 0 => fileno($in), 1 => fileno($out)});
	is(waitpid($pid, 0), $pid, 'waitpid succeeds on hash-object');
	is($?, 0, 'hash-object');
	$out->seek(0, SEEK_SET);
	chomp(my $hashed_obj = <$out>);
	is($hashed_obj, $info->[0], "last object_id matches exp");
}

$im->done;
my @revs = $git->qx(qw(rev-list HEAD));
is(scalar @revs, 1, 'one revision created');

$mime->header_set('Message-ID', '<b@example.com>');
$mime->header_set('Subject', 'msg2');
like($im->add($mime, sub { $mime }), qr/\A:\d+\z/, 'added 2nd message');
$im->done;
@revs = $git->qx(qw(rev-list HEAD));
is(scalar @revs, 2, '2 revisions exist');

is($im->add($mime), undef, 'message only inserted once');
$im->done;
@revs = $git->qx(qw(rev-list HEAD));
is(scalar @revs, 2, '2 revisions exist');

foreach my $c ('c'..'z') {
	$mime->header_set('Message-ID', "<$c\@example.com>");
	$mime->header_set('Subject', "msg - $c");
	like($im->add($mime), qr/\A:\d+\z/, "added $c message");
}
$im->done;
@revs = $git->qx(qw(rev-list HEAD));
is(scalar @revs, 26, '26 revisions exist after mass import');
my ($mark, $msg) = $im->remove($mime);
like($mark, qr/\A:\d+\z/, 'got mark');
is(ref($msg), 'PublicInbox::MIME', 'got old message deleted');

is(undef, $im->remove($mime), 'remove is idempotent');

# mismatch on identical Message-ID
$mime->header_set('Message-ID', '<a@example.com>');
($mark, $msg) = $im->remove($mime);
is($mark, 'MISMATCH', 'mark == MISMATCH on mismatch');
is($msg->header('Message-ID'), '<a@example.com>', 'Message-ID matches');
isnt($msg->header('Subject'), $mime->header('Subject'), 'subject mismatch');

$mime->header_set('Message-Id', '<failcheck@example.com>');
is($im->add($mime, sub { undef }), undef, 'check callback fails');
is($im->remove($mime), undef, 'message not added, so not removed');
is(undef, $im->checkpoint, 'checkpoint works before ->done');
$im->done;
is(undef, $im->checkpoint, 'checkpoint works after ->done');
$im->checkpoint;
done_testing();
