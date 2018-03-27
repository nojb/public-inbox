# Copyright (C) 2013-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use Plack::Util;
use_ok 'PublicInbox::View';

# FIXME: make this test less fragile
my $ctx = {
	env => { HTTP_HOST => 'example.com', 'psgi.url_scheme' => 'http' },
	-inbox => Plack::Util::inline_object(
		name => 'test',
		search => sub { undef },
		base_url => sub { 'http://example.com/' },
		cloneurl => sub {[]},
		nntp_url => sub {[]},
		max_git_part => sub { undef },
		description => sub { '' }),
};
$ctx->{-inbox}->{-primary_address} = 'test@example.com';

sub msg_html ($) {
	my ($mime) = @_;

	my $s = '';
	my $r = PublicInbox::View::msg_html($ctx, $mime);
	my $body = $r->[2];
	while (defined(my $buf = $body->getline)) {
		$s .= $buf;
	}
	$body->close;
	$s;
}

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
	my $html = msg_html($mime);

	# ghetto tests
	like($html, qr!<a\nhref="raw"!s, "raw link present");
	like($html, qr/hello world\b/, "body present");
	like($html, qr/&gt; keep this inline/, "short quoted text is inline");
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

	my $html = msg_html($mime);
	like($html, qr/hi\n.*-- Attachment #2.*\nbye\n/s, "multipart split");
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
				filename => "foo&.patch",
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

	my $html = msg_html($mime);
	like($html, qr!.*Attachment #2: foo&(?:amp|#38);\.patch --!,
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
	my $html = msg_html($mime);
	like($orig, qr/hi =3D bye=/, "our test used QP correctly");
	like($html, qr/\bhi = bye\b/, "HTML output decoded QP");
}

{
	use PublicInbox::MID qw/id_compress/;

	# n.b: this is probably invalid since we dropped CGI for PSGI:
	like(id_compress('foo%bar@wtf'), qr/\A[a-f0-9]{40}\z/,
		"percent always converted to sha1 to workaround buggy httpds");

	is(id_compress('foobar-wtf'), 'foobar-wtf',
		'regular ID not compressed');
}

done_testing();
