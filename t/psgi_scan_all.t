# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::Config;
use PublicInbox::TestCommon;
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape DBD::SQLite);
require_mods(@mods);
use_ok 'PublicInbox::V2Writable';
foreach my $mod (@mods) { use_ok $mod; }
my ($tmp, $for_destroy) = tmpdir();
my $cfg = '';

foreach my $i (1..2) {
	my $cfgpfx = "publicinbox.test-$i";
	my $addr = "test-$i\@example.com";
	my $inboxdir = "$tmp/$i";
	$cfg .= "$cfgpfx.address=$addr\n";
	$cfg .= "$cfgpfx.inboxdir=$inboxdir\n";
	$cfg .= "$cfgpfx.url=http://example.com/$i\n";
	my $opt = {
		inboxdir => $inboxdir,
		name => "test-$i",
		version => 2,
		indexlevel => 'basic',
		-primary_address => $addr,
	};
	my $ibx = PublicInbox::Inbox->new($opt);
	my $im = PublicInbox::V2Writable->new($ibx, 1);
	$im->{parallel} = 0;
	$im->init_inbox(0);
	my $mime = PublicInbox::MIME->new(<<EOF);
From: a\@example.com
To: $addr
Subject: s$i
Message-ID: <a-mid-$i\@b>
Date: Fri, 02 Oct 1993 00:00:00 +0000

hello world
EOF

	ok($im->add($mime), "added message to $i");
	$im->done;
}
my $config = PublicInbox::Config->new(\$cfg);
use_ok 'PublicInbox::WWW';
my $www = PublicInbox::WWW->new($config);

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

done_testing();
