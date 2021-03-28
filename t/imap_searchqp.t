#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Time::Local qw(timegm);
use PublicInbox::TestCommon;
require_mods(qw(-imapd));
use_ok 'PublicInbox::IMAPsearchqp';
use_ok 'PublicInbox::IMAP';

my $imap = bless {}, 'PublicInbox::IMAP';
my $q;
my $parse = sub { PublicInbox::IMAPsearchqp::parse($imap, $_[0]) };

$q = $parse->(qq{BODY oops});
is($q->{xap}, 'b:"oops"', 'BODY key supported');

$q = $parse->(qq{OR HEADER TO Brian (OR FROM Ryan (OR TO Joe CC Scott))});
is($q->{sql}, undef, 'not using SQLite for complex query');
is($q->{xap}, '(t:"brian" OR (f:"ryan" OR (t:"joe" OR c:"scott")))',
	'complex query matches Xapian query string');

$q = $parse->(qq{HEADER CC b SENTSINCE 2-Oct-1993});
is($q->{xap}, 'c:"b" d:19931002..', 'compound query');

$q = $parse->(qq{CHARSET UTF-8 From b});
is($q->{xap}, 'f:"b"', 'charset handled');
$q = $parse->(qq{CHARSET WTF-8 From b});
like($q, qr/\ANO \[/, 'bad charset rejected');
{
	# TODO: squelch errors by default? clients could flood logs
	open my $fh, '>:scalar', \(my $buf) or die;
	local *STDERR = $fh;
	$q = $parse->(qq{CHARSET});
}
like($q, qr/\ABAD /, 'bad charset rejected');

$q = $parse->(qq{HEADER CC B (SENTBEFORE 2-Oct-1993)});
is($q->{xap}, 'c:"b" d:..19931002', 'compound query w/ parens');

{ # limit recursion, stack and CPU cycles ain't free
	my $n = 10;
	my $s = ('('x$n ). 'To a' . ( ')'x$n );
	$q = $parse->($s);
	is($q->{xap}, 't:"a"', 'nesting works');
	++$n;
	$s = ('('x$n ). 'To a' . ( ')'x$n );
	my $err = $parse->($s);
	like($err, qr/\ABAD /, 'reject deep nesting');
}

# IMAP has at least 6 ways of interpreting a date
{
	my $t0 = timegm(0, 0, 0, 2, 10 - 1, 1993);
	my $t1 = $t0 + 86399; # no leap (day|second) support
	my $s;

	$q = $parse->($s = qq{SENTBEFORE 2-Oct-1993});
	is_deeply($q->{sql}, \" AND ds <= $t0", 'SENTBEFORE SQL');
	$q = $parse->("FROM z $s");
	is($q->{xap}, 'f:"z" d:..19931002', 'SENTBEFORE Xapian');

	$q = $parse->($s = qq{SENTSINCE 2-Oct-1993});
	is_deeply($q->{sql}, \" AND ds >= $t0", 'SENTSINCE SQL');
	$q = $parse->("FROM z $s");
	is($q->{xap}, 'f:"z" d:19931002..', 'SENTSINCE Xapian');

	$q = $parse->($s = qq{SENTON 2-Oct-1993});
	is_deeply($q->{sql}, \" AND ds >= $t0 AND ds <= $t1", 'SENTON SQL');
	$q = $parse->("FROM z $s");
	is($q->{xap}, 'f:"z" dt:19931002000000..19931002235959',
		'SENTON Xapian');

	$q = $parse->($s = qq{BEFORE 2-Oct-1993});
	is_deeply($q->{sql}, \" AND ts <= $t0", 'BEFORE SQL');
	$q = $parse->("FROM z $s");
	is($q->{xap}, qq{f:"z" rt:..$t0}, 'BEFORE Xapian');

	$q = $parse->($s = qq{SINCE 2-Oct-1993});
	is_deeply($q->{sql}, \" AND ts >= $t0", 'SINCE SQL');
	$q = $parse->("FROM z $s");
	is($q->{xap}, qq{f:"z" rt:$t0..}, 'SINCE Xapian');

	$q = $parse->($s = qq{ON 2-Oct-1993});
	is_deeply($q->{sql}, \" AND ts >= $t0 AND ts <= $t1", 'ON SQL');
	$q = $parse->("FROM z $s");
	is($q->{xap}, qq{f:"z" rt:$t0..$t1}, 'ON Xapian');
}

{
	$imap->{uo2m} = pack('S*', (1..50000));
	$imap->{uid_base} = 50000;
	my $err = $parse->(qq{9:});
	my $s;

	like($err, qr/\ABAD /, 'bad MSN range');
	$err = $parse->(qq{UID 9:});
	like($err, qr/\ABAD /, 'bad UID range');
	$err = $parse->(qq{FROM x UID 9:});
	like($err, qr/\ABAD /, 'bad UID range with Xapian');
	$err = $parse->(qq{FROM x 9:});
	like($err, qr/\ABAD /, 'bad UID range with Xapian');

	$q = $parse->($s = qq{UID 50009:50099});
	is_deeply($q->{sql}, \' AND (num >= 50009 AND num <= 50099)',
		'SQL generated for UID range');
	$q = $parse->("CC x $s");
	is($q->{xap}, qq{c:"x" uid:50009..50099},
		'Xapian generated for UID range');

	$q = $parse->($s = qq{9:99});
	is_deeply($q->{sql}, \' AND (num >= 50009 AND num <= 50099)',
		'SQL generated for MSN range');
	$q = $parse->("CC x $s");
	is($q->{xap}, qq{c:"x" uid:50009..50099},
		'Xapian generated for MSN range');
}

done_testing;
