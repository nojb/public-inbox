# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::Filter::Mirror';

my $f = PublicInbox::Filter::Mirror->new;
ok($f, 'created PublicInbox::Filter::Mirror object');
{
	my $email = mime_load 't/filter_mirror.eml', sub {
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
				encoding => 'quoted-printable',
			},
			body => 'hi = "bye"',
		)
	];
	Email::MIME->create(
		header_str => [
		  From => 'a@example.com',
		  Subject => 'blah',
		  'Content-Type' => 'multipart/alternative'
		],
		parts => $parts,
	)}; # mime_laod sub
	is($f->ACCEPT, $f->delivery($email), 'accept any trash that comes');
}

 done_testing();
