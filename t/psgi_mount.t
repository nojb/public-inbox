# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir('psgi-path-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for plack.t" if $@;
}
use_ok $_ foreach @mods;
use PublicInbox::Import;
use PublicInbox::Git;
use PublicInbox::Config;
use PublicInbox::WWW;
use Plack::Builder;
use Plack::App::URLMap;
my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => $addr,
	"$cfgpfx.mainrepo" => $maindir,
});
is(0, system(qw(git init -q --bare), $maindir), "git init (main)");
my $git = PublicInbox::Git->new($maindir);
my $im = PublicInbox::Import->new($git, 'test', $addr);
{
	my $mime = Email::MIME->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

zzzzzz
EOF
	$im->add($mime);
	$im->done;
}

my $www = PublicInbox::WWW->new($config);
my $app = builder {
	enable 'Head';
	mount '/a' => builder { sub { $www->call(@_) } };
	mount '/b' => builder { sub { $www->call(@_) } };
};

test_psgi($app, sub {
	my ($cb) = @_;
	my $res;
	# Atom feed:
	$res = $cb->(GET('/a/test/new.atom'));
	like($res->content, qr!\bhttp://[^/]+/a/test/!,
		'URLs which exist in Atom feed are mount-aware');
	unlike($res->content, qr!\b\Qhttp://[^/]+/test/\E!,
		'No URLs which are not mount-aware');

	# redirects
	$res = $cb->(GET('/a/test/blah%40example.com/'));
	is($res->code, 200, 'OK with URLMap mount');
	$res = $cb->(GET('/a/test/blah%40example.com/raw'));
	is($res->code, 200, 'OK with URLMap mount');
	$res = $cb->(GET('/a/test/m/blah%40example.com.html'));
	is($res->header('Location'),
		'http://localhost/a/test/blah@example.com/',
		'redirect functions properly under mount');

	$res = $cb->(GET('/test/blah%40example.com/'));
	is($res->code, 404, 'intentional 404 with URLMap mount');

});

done_testing();
