# Copyright (C) 2018-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::Config;
use PublicInbox::WWW;
require './t/common.perl';
my @mods = qw(DBD::SQLite Search::Xapian HTTP::Request::Common
              Plack::Test URI::Escape Plack::Builder Plack::Test);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for psgi_multipart_not.t" if $@;
}
use_ok($_) for @mods;
use_ok 'PublicInbox::V2Writable';
my ($repo, $for_destroy) = tmpdir();
my $ibx = PublicInbox::Inbox->new({
	inboxdir => $repo,
	name => 'multipart-not',
	version => 2,
	-primary_address => 'test@example.com',
});
my $im = PublicInbox::V2Writable->new($ibx, 1);
$im->{parallel} = 0;

my $mime = PublicInbox::MIME->new(<<'EOF');
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

ok($im->add($mime), 'added broken multipart message');
$im->done;

my $cfgpfx = "publicinbox.v2test";
my $cfg = <<EOF;
$cfgpfx.address=$ibx->{-primary_address}
$cfgpfx.inboxdir=$repo
EOF
my $config = PublicInbox::Config->new(\$cfg);
my $www = PublicInbox::WWW->new($config);

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

done_testing();
1;
