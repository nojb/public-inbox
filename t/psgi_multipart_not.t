#!perl -w
# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Config;
require_git 2.6;
my @mods = qw(DBD::SQLite Search::Xapian HTTP::Request::Common
              Plack::Test URI::Escape Plack::Builder Plack::Test);
require_mods(@mods);
use_ok($_) for (qw(HTTP::Request::Common Plack::Test));
use_ok 'PublicInbox::WWW';
my $ibx = create_inbox 'v2', version => 2, sub {
	my ($im) = @_;
	$im->add(PublicInbox::Eml->new(<<'EOF')) or BAIL_OUT;
Message-Id: <200308111450.h7BEoOu20077@mail.osdl.org>
To: linux-kernel@vger.kernel.org
Subject: [OSDL] linux-2.6.0-test3 reaim results
Mime-Version: 1.0
Content-Type: multipart/mixed ;
	boundary="==_Exmh_120757360"
Date: Mon, 11 Aug 2003 07:50:24 -0700
From: exmh user <x@example.com>

Freed^Wmultipart ain't what it used to be
EOF

};
my $cfgpfx = "publicinbox.v2test";
my $cfg = <<EOF;
$cfgpfx.address=$ibx->{-primary_address}
$cfgpfx.inboxdir=$ibx->{inboxdir}
EOF
my $www = PublicInbox::WWW->new(PublicInbox::Config->new(\$cfg));
my ($res, $raw);
test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	for my $u ('/v2test/?q=%22ain\'t what it used to be%22&x=t',
	           '/v2test/new.atom', '/v2test/new.html') {
		$res = $cb->(GET($u));
		$raw = $res->content;
		ok(index($raw, 'Freed^Wmultipart') >= 0, $u);
		ok(index($raw, 'Warning: decoded text') >= 0, $u.' warns');
	}
});
done_testing;
