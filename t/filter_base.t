# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use_ok 'PublicInbox::Filter::Base';

{
	my $f = PublicInbox::Filter::Base->new;
	ok($f, 'created stock object');
	ok(defined $f->{reject_suffix}, 'rejected suffix redefined');
	is(ref($f->{reject_suffix}), 'Regexp', 'reject_suffix should be a RE');
}

{
	my $f = PublicInbox::Filter::Base->new(reject_suffix => undef);
	ok($f, 'created base object q/o reject_suffix');
	ok(!defined $f->{reject_suffix}, 'reject_suffix not defined');
}

{
	my $f = PublicInbox::Filter::Base->new;
	my $html_body = "<html><body>hi</body></html>";
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'text/xhtml; charset=UTF-8',
				encoding => 'base64',
			},
			body => $html_body,
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				encoding => 'quoted-printable',
			},
			body => 'hi = "bye"',
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
	is($f->delivery($email), 100, "xhtml rejected");
}

{
	my $f = PublicInbox::Filter::Base->new;
	my $parts = [
		Email::MIME->create(
			attributes => {
				content_type => 'application/vnd.ms-excel',
				encoding => 'base64',
			},
			body => 'junk',
		),
		Email::MIME->create(
			attributes => {
				content_type => 'text/plain',
				encoding => 'quoted-printable',
			},
			body => 'junk',
		)
	];
	my $email = Email::MIME->create(
		header_str => [
		  From => 'a@example.com',
		  Subject => 'blah',
		  'Content-Type' => 'multipart/mixed'
		],
		parts => $parts,
	);
	is($f->delivery($email), 100, 'proprietary format rejected on glob');
}

done_testing();
