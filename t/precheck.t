# Copyright (C) 2014-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::Simple;
use PublicInbox::MDA;

sub do_checks {
	my ($s) = @_;

	my $recipient = 'foo@example.com';
	ok(!PublicInbox::MDA->precheck($s, $recipient),
		"wrong ORIGINAL_RECIPIENT rejected");

	$recipient = 'b@example.com';
	ok(PublicInbox::MDA->precheck($s, $recipient),
		"ORIGINAL_RECIPIENT in To: is OK");

	$recipient = 'c@example.com';
	ok(PublicInbox::MDA->precheck($s, $recipient),
		"ORIGINAL_RECIPIENT in Cc: is OK");

	$recipient = [ 'c@example.com', 'd@example.com' ];
	ok(PublicInbox::MDA->precheck($s, $recipient),
		"alias list is OK");
}

{
	my $s = Email::Simple->create(
		header => [
			From => 'abc@example.com',
			To => 'abc@example.com',
			Cc => 'c@example.com, another-list@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'list is fine',
			'Message-ID' => '<MID@host>',
			Date => 'Wed, 09 Apr 2014 01:28:34 +0000',
		],
		body => "hello world\n",
	);
	my $addr = [ 'c@example.com', 'd@example.com' ];
	ok(PublicInbox::MDA->precheck($s, $addr), 'Cc list is OK');
}

{
	do_checks(Email::Simple->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			Cc => 'c@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
			'Message-ID' => '<MID@host>',
			Date => 'Wed, 09 Apr 2014 01:28:34 +0000',
		],
		body => "hello world\n",
	));
}

{
	do_checks(Email::Simple->create(
		header => [
			From => 'a@example.com',
			To => 'b+plus@example.com',
			Cc => 'John Doe <c@example.com>',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
			'Message-ID' => '<MID@host>',
			Date => 'Wed, 09 Apr 2014 01:28:34 +0000',
		],
		body => "hello world\n",
	));
}

{
	my $recipient = 'b@example.com';
	my $s = Email::Simple->create(
		header => [
			To => 'b@example.com',
			Cc => 'c@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
			'Message-ID' => '<MID@host>',
			Date => 'Wed, 09 Apr 2014 01:28:34 +0000',
		],
		body => "hello world\n",
	);
	ok(!PublicInbox::MDA->precheck($s, $recipient),
		"missing From: is rejected");
}

done_testing();
