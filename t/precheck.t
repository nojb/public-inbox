# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::Simple;
use Email::Filter;
use PublicInbox::MDA;

sub do_checks {
	my ($s) = @_;

	my $f = Email::Filter->new(data => $s->as_string);

	ok(PublicInbox::MDA->precheck($f, undef),
		"ORIGINAL_RECIPIENT unset is OK");

	my $recipient = 'foo@example.com';
	ok(!PublicInbox::MDA->precheck($f, $recipient),
		"wrong ORIGINAL_RECIPIENT rejected");

	$recipient = 'b@example.com';
	ok(PublicInbox::MDA->precheck($f, $recipient),
		"ORIGINAL_RECIPIENT in To: is OK");

	$recipient = 'c@example.com';
	ok(PublicInbox::MDA->precheck($f, $recipient),
		"ORIGINAL_RECIPIENT in Cc: is OK");
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
	my $f = Email::Filter->new(data => $s->as_string);
	ok(!PublicInbox::MDA->precheck($f, $recipient),
		"missing From: is rejected");
}

done_testing();
