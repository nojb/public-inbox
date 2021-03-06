# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::ContentId qw(content_id);
use Email::MIME;

my $mime = Email::MIME->create(
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

my $orig = content_id($mime);
my $reload = content_id(Email::MIME->new($mime->as_string));
is($orig, $reload, 'content_id matches after serialization');

done_testing();
