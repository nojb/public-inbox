#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::IMAP;
{
	my $partial_prepare = \&PublicInbox::IMAP::partial_prepare;
	my $x = {};
	my $r = $partial_prepare->($x, [], my $p = 'BODY.PEEK[9]');
	ok($r, $p);
	$r = $partial_prepare->($x, [], $p = 'BODY.PEEK[9]<5>');
	ok($r, $p);
	$r = $partial_prepare->($x, [], $p = 'BODY.PEEK[9]<5.1>');
	ok($r, $p);
	$r = $partial_prepare->($x, [], $p = 'BODY[1.1]');
	ok($r, $p);
	$r = $partial_prepare->($x, [], $p = 'BODY[HEADER.FIELDS (DATE FROM)]');
	ok($r, $p);
	$r = $partial_prepare->($x, [], $p = 'BODY[HEADER.FIELDS.NOT (TO)]');
	ok($r, $p);
	$r = $partial_prepare->($x, [], $p = 'BODY[HEDDER.FIELDS.NOT (TO)]');
	ok(!$r, "rejected misspelling $p");
	$r = $partial_prepare->($x, [], $p = 'BODY[1.1.HEADER.FIELDS (TO)]');
	ok($r, $p);
	my $partial_body = \&PublicInbox::IMAP::partial_body;
	my $partial_hdr_get = \&PublicInbox::IMAP::partial_hdr_get;
	my $partial_hdr_not = \&PublicInbox::IMAP::partial_hdr_not;
	is_deeply($x, {
		'BODY.PEEK[9]' => [ $partial_body, 9, undef, undef, undef ],
		'BODY.PEEK[9]<5>' => [ $partial_body, 9, undef, 5, undef ],
		'BODY.PEEK[9]<5.1>' => [ $partial_body, 9, undef, 5, 1 ],
		'BODY[1.1]' => [ $partial_body, '1.1', undef, undef, undef ],
		'BODY[HEADER.FIELDS (DATE FROM)]' => [ $partial_hdr_get,
					undef, 'DATE FROM', undef, undef ],
		'BODY[HEADER.FIELDS.NOT (TO)]' => [ $partial_hdr_not,
						undef, 'TO', undef, undef ],
		'BODY[1.1.HEADER.FIELDS (TO)]' => [ $partial_hdr_get,
						'1.1', 'TO', undef, undef ],
	}, 'structure matches expected');
}

done_testing;
