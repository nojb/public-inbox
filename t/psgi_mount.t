#!perl -w
# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::Eml;
use PublicInbox::TestCommon;
use PublicInbox::Config;
my ($tmpdir, $for_destroy) = tmpdir();
my $v1dir = "$tmpdir/v1.git";
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape
	Plack::Builder Plack::App::URLMap);
require_mods(@mods);
use_ok $_ foreach @mods;
use_ok 'PublicInbox::WWW';
my $ibx = create_inbox 'test', tmpdir => $v1dir, sub {
	my ($im, $ibx) = @_;
	$im->add(PublicInbox::Eml->new(<<EOF)) or BAIL_OUT;
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $ibx->{-primary_address}
Message-Id: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

zzzzzz
EOF
};
my $cfg = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=$ibx->{-primary_address}
$cfgpfx.inboxdir=$v1dir
EOF
my $www = PublicInbox::WWW->new($cfg);
my $app = builder(sub {
	enable('Head');
	mount('/a' => builder(sub { sub { $www->call(@_) } }));
	mount('/b' => builder(sub { sub { $www->call(@_) } }));
});

test_psgi($app, sub {
	my ($cb) = @_;
	my $res;
	# Atom feed:
	$res = $cb->(GET('/a/test/new.atom'));
	like($res->content, qr!\bhttp://[^/]+/a/test/!,
		'URLs which exist in Atom feed are mount-aware');
	unlike($res->content, qr!\b\Qhttp://[^/]+/test/\E!,
		'No URLs which are not mount-aware');

	$res = $cb->(GET('/a/test/_/text/mirror/'));
	like($res->content, qr!git clone --mirror\s+.*?http://[^/]+/a/test\b!s,
		'clone URL in /text/mirror is mount-aware');

	$res = $cb->(GET('/a/test/blah%40example.com/raw'));
	is($res->code, 200, 'OK with URLMap mount');
	like($res->content,
		qr/^Message-Id: <blah\@example\.com>\n/sm,
		'headers appear in /raw');

	# redirects
	$res = $cb->(GET('/a/test/m/blah%40example.com.html'));
	is($res->header('Location'),
		'http://localhost/a/test/blah@example.com/',
		'redirect functions properly under mount');

	$res = $cb->(GET('/test/blah%40example.com/'));
	is($res->code, 404, 'intentional 404 with URLMap mount');
});

SKIP: {
	require_mods(qw(DBD::SQLite Search::Xapian IO::Uncompress::Gunzip), 3);
	require_ok 'PublicInbox::SearchIdx';
	PublicInbox::SearchIdx->new($ibx, 1)->index_sync;
	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET('/a/test/blah@example.com/t.mbox.gz'));
		my $gz = $res->content;
		my $raw;
		IO::Uncompress::Gunzip::gunzip(\$gz => \$raw);
		like($raw, qr!^Message-Id:\x20<blah\@example\.com>\n!sm,
			'headers appear in /t.mbox.gz mboxrd');
	});
}

done_testing();
