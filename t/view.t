# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::View;

# plain text
{
	my $body = <<EOF;
So and so wrote:
> keep this inline

OK

> Long and wordy reply goes here and it is split across multiple lines.
> We generate links to a separate full page where quoted-text is inline.

hello world
EOF
	my $s = Email::Simple->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			'Message-ID' => '<hello@example.com>',
			Subject => 'this is a subject',
		],
		body => $body,
	);
	$s = Email::MIME->new($s->as_string);
	my $html = PublicInbox::View->as_html($s);

	# ghetto
	like($html, qr/<a href="hello%40/s, "MID link present");
	like($html, qr/hello world\b/, "body present");
	like($html, qr/&gt; keep this inline/, "short quoted text is inline");
	like($html, qr/<a name=[^>]+>&gt; Long and wordy/,
		"long quoted text is anchored");

	# short page
	my $pfx = "http://example.com/test/f";
	my $short = PublicInbox::View->as_html($s, $pfx);
	like($short, qr/\n&gt; keep this inline/,
		"short quoted text is inline");
	like($short, qr/<a href="\Q$pfx\E#[^>]+>Long and wordy/,
		"long quoted text is made into a link");
	ok(length($short) < length($html), "short page is shorter");
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
	like($html, qr/hi\n-+ part #2 -+\nbye\n/, "multipart split");
}

# multipart email with attached patch
{
	my $parts = [
		Email::MIME->create(
			attributes => { content_type => 'text/plain', },
			body => 'hi, see attached patch',
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				filename => "foo.patch",
			},
			body => "--- a/file\n+++ b/file\n" .
			        "@@ -49, 7 +49,34 @@\n",
		),
	];
	my $mime = Email::MIME->create(
		header_str => [
			From => 'a@example.com',
			Subject => '[PATCH] asdf',
			'Message-ID' => '<patch@example.com>',
			],
		parts => $parts,
	);

	my $html = PublicInbox::View->as_html($mime);
	like($html, qr!see attached patch\n-+ foo\.patch -+\n--- a/file\n!,
		"parts split with filename");
}

done_testing();
