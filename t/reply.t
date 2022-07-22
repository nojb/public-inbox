#!perl -w
# Copyright (C) 2017-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::Config;
use PublicInbox::Eml;
use_ok 'PublicInbox::Reply';

my @q = (
	'foo@bar', 'foo@bar',
	'a b', "'a b'",
	"a'b", "'a'\\''b'",
);

while (@q) {
	my $input = shift @q;
	my $expect = shift @q;
	my $res = PublicInbox::Config::squote_maybe($input);
	is($res, $expect, "quote $input => $res");
}

my $mime = PublicInbox::Eml->new(<<'EOF');
From: from <from@example.com>
To: to <to@example.com>
Cc: cc@example.com
Message-Id: <blah@example.com>
Subject: hihi

EOF

my $hdr = $mime->header_obj;
my $ibx = { -primary_address => 'primary@example.com' };

my ($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
my $exp = [
    '--in-reply-to=blah@example.com',
    '--to=from@example.com',
    '--cc=cc@example.com',
    '--cc=to@example.com',
];

is_deeply($arg, $exp, 'default reply is to :all');
$ibx->{replyto} = ':all';
($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
is_deeply($arg, $exp, '":all" also works');

$exp = [ '--in-reply-to=blah@example.com', '--to=primary@example.com' ];
$ibx->{replyto} = ':list';
($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
is_deeply($arg, $exp, '":list" works for centralized lists');

$exp = [
	 '--in-reply-to=blah@example.com',
	 '--to=primary@example.com',
	 '--cc=cc@example.com',
	 '--cc=to@example.com',
];
$ibx->{replyto} = ':list,Cc,To';
($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
is_deeply($arg, $exp, '":list,Cc,To" works for kinda centralized lists');

$ibx->{replyto} = 'new@example.com';
($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
$exp = [ '--in-reply-to=blah@example.com', '--to=new@example.com' ];
is_deeply($arg, $exp, 'explicit address works, too');

$ibx->{replyto} = ':all';
$ibx->{obfuscate} = 1;
($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
$exp = [
    '--in-reply-to=blah@example.com',
    '--to=from@example$(echo .)com',
    '--cc=cc@example$(echo .)com',
    '--cc=to@example$(echo .)com',
];
is_deeply($arg, $exp, 'address obfuscation works');
is($link, '', 'no mailto: link given');

$ibx->{replyto} = ':none=dead list';
$ibx->{obfuscate} = 1;
($arg, $link) = PublicInbox::Reply::mailto_arg_link($ibx, $hdr);
is($$arg, 'dead list', ':none= works');

done_testing();
