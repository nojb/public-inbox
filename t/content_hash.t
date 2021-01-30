#!perl -w
# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::ContentHash qw(content_hash);
use PublicInbox::Eml;

my $mime = PublicInbox::Eml->new(<<'EOF');
From: a@example.com
To: b@example.com
Subject: this is a subject
Message-ID: <a@example.com>
Date: Fri, 02 Oct 1993 00:00:00 +0000

hello world
EOF

my $orig = content_hash($mime);
my $reload = content_hash(PublicInbox::Eml->new($mime->as_string));
is($orig, $reload, 'content_hash matches after serialization');
{
	my $s1 = PublicInbox::Eml->new($mime->as_string);
	$s1->header_set('Sender', 's@example.com');
	is(content_hash($s1), $orig, "Sender ignored when 'From' present");
	my $s2 = PublicInbox::Eml->new($s1->as_string);
	$s1->header_set('Sender', 'sender@example.com');
	is(content_hash($s2), $orig, "Sender really ignored 'From'");
	$_->header_set('From') for ($s1, $s2);
	isnt(content_hash($s1), content_hash($s2),
		'sender accounted when From missing');
}

foreach my $h (qw(From To Cc)) {
	my $n = q("Quoted N'Ame" <foo@EXAMPLE.com>);
	$mime->header_set($h, "$n");
	my $q = content_hash($mime);
	is($mime->header($h), $n, "content_hash does not mutate $h:");
	$mime->header_set($h, 'Quoted N\'Ame <foo@example.com>');
	my $nq = content_hash($mime);
	is($nq, $q, "quotes ignored in $h:");
}

done_testing();
