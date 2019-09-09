# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir('psgi-text-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for psgi_text.t" if $@;
}
use_ok $_ foreach @mods;
use PublicInbox::Import;
use PublicInbox::Git;
use PublicInbox::Config;
use PublicInbox::WWW;
use_ok 'PublicInbox::WwwText';
use Plack::Builder;
my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => $addr,
	"$cfgpfx.mainrepo" => $maindir,
});
is(0, system(qw(git init -q --bare), $maindir), "git init (main)");
my $www = PublicInbox::WWW->new($config);

test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	my $res;
	$res = $cb->(GET('/test/_/text/help/'));
	like($res->content, qr!<title>public-inbox help.*</title>!,
		'default help');
});

done_testing();
