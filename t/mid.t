# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use Test::More;
use PublicInbox::MID qw(mid_escape mids references);

is(mid_escape('foo!@(bar)'), 'foo!@(bar)');
is(mid_escape('foo%!@(bar)'), 'foo%25!@(bar)');
is(mid_escape('foo%!@(bar)'), 'foo%25!@(bar)');

{
	use Email::MIME;
	my $mime = Email::MIME->create;
	$mime->header_set('Message-Id', '<mid-1@a>');
	is_deeply(['mid-1@a'], mids($mime->header_obj), 'mids in common case');
	$mime->header_set('Message-Id', '<mid-1@a>', '<mid-2@b>');
	is_deeply(['mid-1@a', 'mid-2@b'], mids($mime->header_obj), '2 mids');
	$mime->header_set('Message-Id', '<mid-1@a>', '<mid-1@a>');
	is_deeply(['mid-1@a'], mids($mime->header_obj), 'dup mids');
	$mime->header_set('Message-Id', '<mid-1@a> comment');
	is_deeply(['mid-1@a'], mids($mime->header_obj), 'comment ignored');
	$mime->header_set('Message-Id', 'bare-mid');
	is_deeply(['bare-mid'], mids($mime->header_obj), 'bare mid OK');

	$mime->header_set('References', '<hello> <world>');
	$mime->header_set('In-Reply-To', '<weld>');
	is_deeply(['hello', 'world', 'weld'], references($mime->header_obj),
		'references combines with In-Reply-To');
}

done_testing();
1;
