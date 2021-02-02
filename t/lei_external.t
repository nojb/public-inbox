#!perl -w
use strict;
use v5.10.1;
use Test::More;
my $cls = 'PublicInbox::LeiExternal';
require_ok $cls;
my $canon = $cls->can('ext_canonicalize');
my $exp = 'https://example.com/my-inbox/';
is($canon->('https://example.com/my-inbox'), $exp, 'trailing slash added');
is($canon->('https://example.com/my-inbox//'), $exp, 'trailing slash removed');
is($canon->('https://example.com//my-inbox/'), $exp, 'leading slash removed');
is($canon->('https://EXAMPLE.com/my-inbox/'), $exp, 'lowercased');
is($canon->('/this/path/is/nonexistent/'), '/this/path/is/nonexistent',
	'non-existent pathname canonicalized');
is($canon->('/this//path/'), '/this/path', 'extra slashes gone');
is($canon->('/ALL/CAPS'), '/ALL/CAPS', 'caps preserved');

done_testing;
