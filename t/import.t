# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::Git;
use PublicInbox::Import;
use File::Temp qw/tempdir/;
my $dir = tempdir('pi-import-XXXXXX', TMPDIR => 1, CLEANUP => 1);

is(system(qw(git init -q --bare), $dir), 0, 'git init successful');
my $git = PublicInbox::Git->new($dir);

my $im = PublicInbox::Import->new($git, 'testbox', 'test@example');
my $mime = Email::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'b@example.com',
		'Content-Type' => 'text/plain',
		Subject => 'this is a subject',
		'Message-ID' => '<a@example.com>',
	],
	body => "hello world\n",
);
like($im->add($mime), qr/\A:\d+\z/, 'added one message');
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
is(ref($msg), 'Email::MIME', 'got old message deleted');

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

$im->done;
done_testing();
