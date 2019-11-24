# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
require './t/common.perl';
require_git(2.6);

foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for v2-add-remove-add.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
my ($inboxdir, $for_destroy) = tmpdir();
my $ibx = {
	inboxdir => "$inboxdir/v2",
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
		'Message-ID' => '<a-mid@b>',
	],
	body => "hello world\n",
);
my $im = PublicInbox::V2Writable->new($ibx, 1);
$im->{parallel} = 0;
ok($im->add($mime), 'message added');
ok($im->remove($mime), 'message added');
ok($im->add($mime), 'message added again');
$im->done;
my $msgs = $ibx->recent({limit => 1000});
is($msgs->[0]->{mid}, 'a-mid@b', 'message exists in history');
is(scalar @$msgs, 1, 'only one message in history');

done_testing();
