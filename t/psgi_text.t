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
require_mods(@mods);
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
	my $res;
	$res = $cb->(GET('/test/_/text/help/'));
	like($res->content, qr!<title>public-inbox help.*</title>!,
		'default help');
	$res = $cb->(GET('/test/_/text/config/raw'));
	my $f = "$tmpdir/cfg";
	open my $fh, '>', $f or die;
	print $fh $res->content or die;
	close $fh or die;
	my $cfg = PublicInbox::Config->new($f);
	is($cfg->{"$cfgpfx.address"}, $addr, 'got expected address in config');
});

done_testing();
