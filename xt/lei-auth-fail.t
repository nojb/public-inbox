#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;

# TODO: mock IMAP server which fails at authentication so we don't
# have to make external connections to test this:
my $imap_fail = $ENV{TEST_LEI_IMAP_FAIL_URL} //
	'imaps://AzureDiamond:Hunter2@public-inbox.org:994/INBOX';
test_lei(sub {
	ok(!lei(qw(convert -o mboxrd:/dev/stdout), $imap_fail),
		'IMAP auth failure on convert');
	like($lei_err, qr!\bE:.*?imaps://.*?!sm, 'error shown');
	unlike($lei_err, qr!Hunter2!s, 'password not shown');
	is($lei_out, '', 'nothing output');
	ok(!lei(qw(import), $imap_fail), 'IMAP auth failure on import');
	like($lei_err, qr!\bE:.*?imaps://.*?!sm, 'error shown');
	unlike($lei_err, qr!Hunter2!s, 'password not shown');
});
done_testing;
