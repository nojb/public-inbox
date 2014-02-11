# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::Simple;
use Email::Filter;
use PublicInbox;

sub do_checks {
	my ($s) = @_;

	my $f = Email::Filter->new(data => $s->as_string);
	local %ENV;
	delete $ENV{ORIGINAL_RECIPIENT};

	ok(PublicInbox->precheck($f),
		"ORIGINAL_RECIPIENT unset is OK");

	$ENV{ORIGINAL_RECIPIENT} = 'foo@example.com';
	ok(!PublicInbox->precheck($f),
		"wrong ORIGINAL_RECIPIENT rejected");

	$ENV{ORIGINAL_RECIPIENT} = 'b@example.com';
	ok(PublicInbox->precheck($f),
		"ORIGINAL_RECIPIENT in To: is OK");

	$ENV{ORIGINAL_RECIPIENT} = 'c@example.com';
	ok(PublicInbox->precheck($f),
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
		],
		body => "hello world\n",
	));
}

{
	$ENV{ORIGINAL_RECIPIENT} = 'b@example.com';
	my $s = Email::Simple->create(
		header => [
			To => 'b@example.com',
			Cc => 'c@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'this is a subject',
		],
		body => "hello world\n",
	);
	my $f = Email::Filter->new(data => $s->as_string);
	ok(!PublicInbox->precheck($f), "missing From: is rejected");
}

done_testing();
