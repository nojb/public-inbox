# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape Plack::Builder);
require_mods(@mods, 'IO::Uncompress::Gunzip');
use_ok $_ foreach @mods;
use PublicInbox::Import;
use PublicInbox::Git;
use PublicInbox::Config;
use_ok 'PublicInbox::WWW';
use_ok 'PublicInbox::WwwText';
my $config = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=$addr
$cfgpfx.inboxdir=$maindir
EOF
PublicInbox::Import::init_bare($maindir);
my $www = PublicInbox::WWW->new($config);

test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	my $gunzipped;
	my $req = GET('/test/_/text/help/');
	my $res = $cb->($req);
	my $content = $res->content;
	like($content, qr!<title>public-inbox help.*</title>!, 'default help');
	$req->header('Accept-Encoding' => 'gzip');
	$res = $cb->($req);
	is($res->header('Content-Encoding'), 'gzip', 'got gzip encoding');
	is($res->header('Content-Type'), 'text/html; charset=UTF-8',
		'got gzipped HTML');
	IO::Uncompress::Gunzip::gunzip(\($res->content) => \$gunzipped);
	is($gunzipped, $content, 'gzipped content is correct');

	$req = GET('/test/_/text/config/raw');
	$res = $cb->($req);
	$content = $res->content;
	my $olen = $res->header('Content-Length');
	my $f = "$tmpdir/cfg";
	open my $fh, '>', $f or die;
	print $fh $content or die;
	close $fh or die;
	my $cfg = PublicInbox::Config->new($f);
	is($cfg->{"$cfgpfx.address"}, $addr, 'got expected address in config');

	$req->header('Accept-Encoding' => 'gzip');
	$res = $cb->($req);
	is($res->header('Content-Encoding'), 'gzip', 'got gzip encoding');
	ok($res->header('Content-Length') < $olen, 'gzipped help is smaller');
	IO::Uncompress::Gunzip::gunzip(\($res->content) => \$gunzipped);
	is($gunzipped, $content);
});

done_testing();
