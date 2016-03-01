# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Linkify;

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-trailing-period';
	my $s = $u . '.';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>.), 'trailing period not in URL');
}

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-trailing-semicolon';
	my $s = $u . ';';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>;), 'trailing semicolon not in URL');
}

done_testing();
