# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
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
	my $s = PublicInbox::Eml->new(<<'EOF');
From: abc@example.com
To: abc@example.com
Cc: c@example.com, another-list@example.com
Content-Type: text/plain
Subject: list is fine
Message-ID: <MID@host>
Date: Wed, 09 Apr 2014 01:28:34 +0000

hello world
EOF
	my $addr = [ 'c@example.com', 'd@example.com' ];
	ok(PublicInbox::MDA->precheck($s, $addr), 'Cc list is OK');
}

{
	do_checks(PublicInbox::Eml->new(<<'EOF'));
From: a@example.com
To: b@example.com
Cc: c@example.com
Content-Type: text/plain
Subject: this is a subject
Message-ID: <MID@host>
Date: Wed, 09 Apr 2014 01:28:34 +0000

hello world
EOF
}

{
	do_checks(PublicInbox::Eml->new(<<'EOF'));
From: a@example.com
To: b+plus@example.com
Cc: John Doe <c@example.com>
Content-Type: text/plain
Subject: this is a subject
Message-ID: <MID@host>
Date: Wed, 09 Apr 2014 01:28:34 +0000

hello world
EOF
}

{
	my $recipient = 'b@example.com';
	my $s = PublicInbox::Eml->new(<<'EOF');
To: b@example.com
Cc: c@example.com
Content-Type: text/plain
Subject: this is a subject
Message-ID: <MID@host>
Date: Wed, 09 Apr 2014 01:28:34 +0000

hello world
EOF
	ok(!PublicInbox::MDA->precheck($s, $recipient),
		"missing From: is rejected");
}

done_testing();
