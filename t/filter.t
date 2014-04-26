# Copyright (C) 2013, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::Filter;

sub count_body_parts {
	my ($bodies, $part) = @_;
	my $body = $part->body_raw;
	$body =~ s/\A\s*//;
	$body =~ s/\s*\z//;
	$bodies->{$body} ||= 0;
	$bodies->{$body}++;
}

# plain-text email is passed through unchanged
{
	my $s = Email::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
		],
		body => "hello world\n",
	);
	is(1, PublicInbox::Filter->run($s), "run was a success");
}

# convert single-part HTML to plain-text
{
	my $s = Email::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/html',
			Subject => 'HTML only badness',
		],
		body => "<html><body>bad body</body></html>\n",
	);
	is(1, PublicInbox::Filter->run($s), "run was a success");
	unlike($s->as_string, qr/<html>/, "HTML removed");
	is("text/plain", $s->header("Content-Type"),
		"content-type changed");
	like($s->body, qr/\A\s*bad body\s*\z/, "body");
	like($s->header("X-Content-Filtered-By"),
		qr/PublicInbox::Filter/, "XCFB header added");
}

# multipart/alternative: HTML and plain-text, keep the plain-text
{
	my $html_body = "<html><body>hi</body></html>";
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'text/html; charset=UTF-8',
				encoding => 'base64',
			},
			body => $html_body,
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
			},
			body=> 'hi',
		)
	];
	my $email = Email::MIME->create(
		header_str => [
		  From => 'a@example.com',
		  Subject => 'blah',
		  'Content-Type' => 'multipart/alternative'
		],
		parts => $parts,
	);
	is(1, PublicInbox::Filter->run($email), "run was a success");
	my $parsed = Email::MIME->new($email->as_string);
	is("text/plain", $parsed->header("Content-Type"));
	is(scalar $parsed->parts, 1, "HTML part removed");
	my %bodies;
	$parsed->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		count_body_parts(\%bodies, $part);
	});
	is(scalar keys %bodies, 1, "one bodies");
	is($bodies{"hi"}, 1, "plain text part unchanged");
}

# multi-part plain-text-only
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
	my $email = Email::MIME->create(
		header_str => [ From => 'a@example.com', Subject => 'blah' ],
		parts => $parts,
	);
	is(1, PublicInbox::Filter->run($email), "run was a success");
	my $parsed = Email::MIME->new($email->as_string);
	is(scalar $parsed->parts, 2, "still 2 parts");
	my %bodies;
	$parsed->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		count_body_parts(\%bodies, $part);
	});
	is(scalar keys %bodies, 2, "two bodies");
	is($bodies{"bye"}, 1, "bye part exists");
	is($bodies{"hi"}, 1, "hi part exists");
	is($parsed->header("X-Content-Filtered-By"), undef,
		"XCFB header unset");
}

# multi-part HTML, several HTML parts
{
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'text/html',
				encoding => 'base64',
			},
			body => '<html><body>b64 body</body></html>',
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/html',
				encoding => 'quoted-printable',
			},
			body => '<html><body>qp body</body></html>',
		)
	];
	my $email = Email::MIME->create(
		header_str => [ From => 'a@example.com', Subject => 'blah' ],
		parts => $parts,
	);
	is(1, PublicInbox::Filter->run($email), "run was a success");
	my $parsed = Email::MIME->new($email->as_string);
	is(scalar $parsed->parts, 2, "still 2 parts");
	my %bodies;
	$parsed->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		count_body_parts(\%bodies, $part);
	});
	is(scalar keys %bodies, 2, "two body parts");
	is($bodies{"b64 body"}, 1, "base64 part converted");
	is($bodies{"qp body"}, 1, "qp part converted");
	like($parsed->header("X-Content-Filtered-By"), qr/PublicInbox::Filter/,
	     "XCFB header added");
}

# plain-text with image attachments, kill images
{
	my $parts = [
		Email::MIME->create(
			attributes => { content_type => 'text/plain' },
			body => 'see image',
		),
		Email::MIME->create(
			attributes => {
				content_type => 'image/jpeg',
				filename => 'scary.jpg',
				encoding => 'base64',
			},
			body => 'bad',
		)
	];
	my $email = Email::MIME->create(
		header_str => [ From => 'a@example.com', Subject => 'blah' ],
		parts => $parts,
	);
	is(1, PublicInbox::Filter->run($email), "run was a success");
	my $parsed = Email::MIME->new($email->as_string);
	is(scalar $parsed->parts, 1, "image part removed");
	my %bodies;
	$parsed->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		count_body_parts(\%bodies, $part);
	});
	is(scalar keys %bodies, 1, "one body");
	is($bodies{'see image'}, 1, 'original body exists');
	like($parsed->header("X-Content-Filtered-By"), qr/PublicInbox::Filter/,
	     "XCFB header added");
}

# all bad
{
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'image/jpeg',
				filename => 'scary.jpg',
				encoding => 'base64',
			},
			body => 'bad',
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				filename => 'scary.exe',
				encoding => 'base64',
			},
			body => 'bad',
		),
	];
	my $email = Email::MIME->create(
		header_str => [ From => 'a@example.com', Subject => 'blah' ],
		parts => $parts,
	);
	is(0, PublicInbox::Filter->run($email),
		"run signaled to stop delivery");
	my $parsed = Email::MIME->new($email->as_string);
	is(scalar $parsed->parts, 1, "bad parts removed");
	my %bodies;
	$parsed->walk_parts(sub {
		my ($part) = @_;
		return if $part->subparts; # walk_parts already recurses
		count_body_parts(\%bodies, $part);
	});
	is(scalar keys %bodies, 1, "one body");
	is($bodies{"all attachments scrubbed by PublicInbox::Filter"}, 1,
	   "attachment scrubber left its mark");
	like($parsed->header("X-Content-Filtered-By"), qr/PublicInbox::Filter/,
	     "XCFB header added");
}

{
	my $s = Email::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'test/pain',
			Subject => 'this is a subject',
		],
		body => "hello world\n",
	);
	is(0, PublicInbox::Filter->run($s), "run was a failure");
	like($s->as_string, qr/scrubbed/, "scrubbed message");
}

{
	my $s = Email::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			'Mail-Followup-To' => 'c@example.com',
			Subject => 'mfttest',
		],
		body => "mft\n",
	);

	is('c@example.com', $s->header("Mail-Followup-To"),
		"mft set correctly");
	is(1, PublicInbox::Filter->run($s), "run succeeded for mft");
	is(undef, $s->header("Mail-Followup-To"), "mft stripped");
}

# multi-part with application/octet-stream
{
	my $os = 'application/octet-stream';
	my $parts = [
		Email::MIME->create(
			attributes => { content_type => $os },
			body => <<EOF
#include <stdio.h>
int main(void)
{
	printf("Hello world\\n");
	return 0;
}

/* some folks like ^L */
EOF
		),
		Email::MIME->create(
			attributes => {
				filename => 'zero.data',
				encoding => 'base64',
				content_type => $os,
			},
			body => ("\0" x 4096),
		)
	];
	my $email = Email::MIME->create(
		header_str => [ From => 'a@example.com', Subject => 'blah' ],
		parts => $parts,
	);
	is(1, PublicInbox::Filter->run($email), "run was a success");
	my $parsed = Email::MIME->new($email->as_string);
	is(scalar $parsed->parts, 1, "only one remaining part");
	like($parsed->header("X-Content-Filtered-By"),
		qr/PublicInbox::Filter/, "XCFB header added");
}

done_testing();
