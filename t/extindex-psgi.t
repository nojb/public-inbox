#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use File::Copy qw(cp);
use IO::Handle ();
require_git(2.6);
require_mods(qw(json DBD::SQLite Search::Xapian
		HTTP::Request::Common Plack::Test URI::Escape Plack::Builder));
use_ok($_) for (qw(HTTP::Request::Common Plack::Test));
require PublicInbox::WWW;
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $home = "$tmpdir/home";
mkdir $home or BAIL_OUT $!;
mkdir "$home/.public-inbox" or BAIL_OUT $!;
my $pi_config = "$home/.public-inbox/config";
cp("$ro_home/.public-inbox/config", $pi_config) or BAIL_OUT;
my $env = { HOME => $home };
run_script([qw(-extindex --all), "$tmpdir/eidx"], $env) or BAIL_OUT;
{
	open my $cfgfh, '>', $pi_config or BAIL_OUT;
	$cfgfh->autoflush(1);
	print $cfgfh <<EOM or BAIL_OUT;
[extindex "all"]
	topdir = $tmpdir/eidx
	url = http://bogus.example.com/all
EOM
}
my $www = PublicInbox::WWW->new(PublicInbox::Config->new($pi_config));
my $client = sub {
	my ($cb) = @_;
	my $res = $cb->(GET('/all/'));
	is($res->code, 200, '/all/ good');
	$res = $cb->(GET('/all/new.atom', Host => 'usethis.example.com'));
	like($res->content, qr!http://usethis\.example\.com/!s,
		'Host: header respected in Atom feed');
	unlike($res->content, qr!http://bogus\.example\.com/!s,
		'default URL ignored with different host header');
};
test_psgi(sub { $www->call(@_) }, $client);
%$env = (%$env, TMPDIR => $tmpdir, PI_CONFIG => $pi_config);
test_httpd($env, $client);

done_testing;
