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
> This is
>
> Currently 12 lines
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED
> See MAX_INLINE_QUOTED

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
	)->as_string;
	my $mime = Email::MIME->new($s);
	my $html = PublicInbox::View->msg_html($mime);

	# ghetto tests
	like($html, qr!<a\nhref="\.\./m/hello%40!s, "MID link present");
	like($html, qr/hello world\b/, "body present");
	like($html, qr/&gt; keep this inline/, "short quoted text is inline");
	like($html, qr/<a\nid=[^>]+>&gt; Long and wordy/,
		"long quoted text is anchored");

	# short page
	my $pfx = "http://example.com/test/f";
	$mime = Email::MIME->new($s);
	my $short = PublicInbox::View->msg_html($mime, $pfx);
	like($short, qr!<a\nhref="hello%40!s, "MID link present");
	like($short, qr/\n&gt; keep this inline/,
		"short quoted text is inline");
	like($short, qr/<a\nhref="\Q$pfx\E#[^>]+>Long and wordy/,
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

	my $html = PublicInbox::View->msg_html($mime);
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

	my $html = PublicInbox::View->msg_html($mime);
	like($html, qr!see attached patch\n-+ foo\.patch -+\n--- a/file\n!,
		"parts split with filename");
}

# multipart collapsed to single quoted-printable text/plain
{
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				encoding => 'quoted-printable',
			},
			body => 'hi = bye',
		)
	];
	my $mime = Email::MIME->create(
		header_str => [
			From => 'qp@example.com',
			Subject => 'QP',
			'Message-ID' => '<qp@example.com>',
			],
		parts => $parts,
	);

	my $orig = $mime->body_raw;
	my $html = PublicInbox::View->msg_html($mime);
	like($orig, qr/hi =3D bye=/, "our test used QP correctly");
	like($html, qr/\bhi = bye\b/, "HTML output decoded QP");
}


{	# XXX dirty hack
	use PublicInbox::MID qw/mid_compressed/;
	like(mid_compressed('foo%bar@wtf'), qr/\A[a-f0-9]{40}\z/,
		"percent always converted to sha1 to workaround buggy httpds");
	is(mid_compressed('foobar@wtf'), 'foobar@wtf',
		'regular MID not compressed');
}

done_testing();
