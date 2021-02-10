#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# internal unit test, see t/lei-externals.t for functional tests
use strict; use v5.10.1; use Test::More;
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

my $glob2re = $cls->can('glob2re');
is($glob2re->('foo'), undef, 'plain string unchanged');
is_deeply($glob2re->('[f-o]'), '[f-o]' , 'range accepted');
is_deeply($glob2re->('*'), '[^/]*?' , 'wildcard accepted');
is_deeply($glob2re->('{a,b,c}'), '(a|b|c)' , 'braces');
is_deeply($glob2re->('{,b,c}'), '(|b|c)' , 'brace with empty @ start');
is_deeply($glob2re->('{a,b,}'), '(a|b|)' , 'brace with empty @ end');
is_deeply($glob2re->('{a}'), undef, 'ungrouped brace');
is_deeply($glob2re->('{a'), undef, 'open left brace');
is_deeply($glob2re->('a}'), undef, 'open right brace');
is_deeply($glob2re->('*.[ch]'), '[^/]*?\\.[ch]', 'suffix glob');
is_deeply($glob2re->('{[a-z],9,}'), '([a-z]|9|)' , 'brace with range');
is_deeply($glob2re->('\\{a,b\\}'), undef, 'escaped brace');
is_deeply($glob2re->('\\\\{a,b}'), '\\\\\\\\(a|b)', 'fake escape brace');

done_testing;
