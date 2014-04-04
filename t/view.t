# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::View;

# plain text
{
	my $s = Email::Simple->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			'Message-ID' => '<hello@example.com>',
			Subject => 'this is a subject',
		],
		body => "hello world\n",
	);
	$s = Email::MIME->new($s->as_string);
	my $html = PublicInbox::View->as_html($s);

	# ghetto
	like($html, qr/<a href="?hello%40/s, "MID link present");
	like($html, qr/hello world\b/, "body present");
}

# multipart crap
{
	my $parts = [
		Email::MIME->create(
			attributes => { content_type => 'text/plain', },
			body => 'hi',
		),
		Email::MIME->create(
			attributes => { content_type => 'text/plain', },
			body => 'bye',
		)
	];
	my $mime = Email::MIME->create(
		header_str => [
			From => 'a@example.com',
			Subject => 'blargh',
			'Message-ID' => '<blah@example.com>',
			'In-Reply-To' => '<irp@example.com>',
			],
		parts => $parts,
	);

	my $html = PublicInbox::View->as_html($mime);
	print $html;
}

done_testing();
