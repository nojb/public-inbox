# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::MIME';
use PublicInbox::MsgTime qw(msg_datestamp);
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		'Message-ID' => '<a-mid@b>',
		Date => 'Fri, 02 Oct 93 00:00:00 +0000',
	],
	body => "hello world\n",
);

my $ts = msg_datestamp($mime->header_obj);
use POSIX qw(strftime);
is(strftime('%Y-%m-%d %H:%M:%S', gmtime($ts)), '1993-10-02 00:00:00',
	'got expected date with 2 digit year');
$mime->header_set(Date => 'Fri, 02 Oct 101 01:02:03 +0000');
$ts = msg_datestamp($mime->header_obj);
is(strftime('%Y-%m-%d %H:%M:%S', gmtime($ts)), '2001-10-02 01:02:03',
	'got expected date with 3 digit year');

done_testing();
