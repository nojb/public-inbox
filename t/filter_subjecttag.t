# Copyright (C) 2017 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use_ok 'PublicInbox::Filter::SubjectTag';

my $f = eval { PublicInbox::Filter::SubjectTag->new };
like($@, qr/tag not defined/, 'error without args');
$f = PublicInbox::Filter::SubjectTag->new('-tag', '[foo]');
is(ref $f, 'PublicInbox::Filter::SubjectTag', 'new object created');

my $mime = Email::MIME->new(<<EOF);
To: you <you\@example.com>
Subject: =?UTF-8?B?UmU6IFtmb29dIEVsw4PCqWFub3I=?=

EOF

$mime = $f->delivery($mime);
is($mime->header('Subject'), "Re: El\xc3\xa9anor", 'filtered with Re:');

$mime->header_str_set('Subject', '[FOO] bar');
$mime = $f->delivery($mime);
is($mime->header('Subject'), 'bar', 'filtered non-reply');

done_testing();
