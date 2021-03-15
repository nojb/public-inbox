#!perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Config;
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape DBD::SQLite);
require_git 2.6;
require_mods(@mods);
use_ok 'PublicInbox::WWW';
foreach my $mod (@mods) { use_ok $mod; }
my $cfg = '';
foreach my $i (1..2) {
	my $ibx = create_inbox "test-$i", version => 2, indexlevel => 'basic',
	sub {
		my ($im, $ibx) = @_;
		$im->add(PublicInbox::Eml->new(<<EOF)) or BAIL_OUT;
From: a\@example.com
To: $ibx->{-primary_address}
Subject: s$i
Message-ID: <a-mid-$i\@b>
Date: Fri, 02 Oct 1993 00:00:00 +0000

hello world
EOF
	};
	my $cfgpfx = "publicinbox.test-$i";
	$cfg .= "$cfgpfx.address=$ibx->{-primary_address}\n";
	$cfg .= "$cfgpfx.inboxdir=$ibx->{inboxdir}\n";
	$cfg .= "$cfgpfx.url=http://example.com/$i\n";

}
my $www = PublicInbox::WWW->new(PublicInbox::Config->new(\$cfg));

test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	foreach my $i (1..2) {
		foreach my $end ('', '/') {
			my $res = $cb->(GET("/a-mid-$i\@b$end"));
			is($res->code, 302, 'got 302');
			is($res->header('Location'),
				"http://example.com/$i/a-mid-$i\@b/",
				"redirected OK to $i");
		}
	}
	foreach my $x (qw(inv@lid inv@lid/ i/v/a l/i/d/)) {
		my $res = $cb->(GET("/$x"));
		is($res->code, 404, "404 on $x");
	}
});
done_testing;
