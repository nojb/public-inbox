#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
use PublicInbox::TestCommon;
use PublicInbox::Config; # this relies on PI_CONFIG // ~/.public-inbox/config
my @psgi = qw(HTTP::Request::Common Plack::Test URI::Escape Plack::Builder);
require_mods(qw(DBD::SQLite Search::Xapian), @psgi);
use_ok($_) for @psgi;
use_ok 'PublicInbox::WWW';
my $cfg = PublicInbox::Config->new;
my $www = PublicInbox::WWW->new($cfg);
my $app = sub {
	my $env = shift;
	$env->{'psgi.errors'} = \*STDERR;
	$www->call($env);
};

# TODO: convert these to self-contained test cases
my $todo = {
	'git' => [
		'9e9048b02bd04d287461543d85db0bb715b89f8c'
			.'/s/?b=t%2Ft3420%2Fremove-ids.sed',
		'eebf7a8/s/?b=t%2Ftest-lib.sh',
		'eb580ca513/s/?b=remote-odb.c',
		'776fa90f7f/s/?b=contrib/git-jump/git-jump',
		'5cd8845/s/?b=submodule.c',
		'81c1164ae5/s/?b=builtin/log.c',
		'6aa8857a11/s/?b=protocol.c',
		'96f1c7f/s/', # TODO: b=contrib/completion/git-completion.bash
		'b76f2c0/s/?b=po/zh_CN.po',
	],
};

my ($ibx_name, $urls, @gone);
my $client = sub {
	my ($cb) = @_;
	for (@$urls) {
		my $url = "/$ibx_name/$_";
		my $res = $cb->(GET($url));
		is($res->code, 200, $url);
		next if $res->code == 200;
		diag "$url failed";
		diag $res->content;
	}
};

my $nr = 0;
while (($ibx_name, $urls) = each %$todo) {
	SKIP: {
		if (!$cfg->lookup_name($ibx_name)) {
			push @gone, $ibx_name;
			skip("$ibx_name not configured", scalar(@$urls));
		}
		test_psgi($app, $client);
		$nr++;
	}
}

SKIP: {
	require_mods(qw(Plack::Test::ExternalServer), $nr);
	delete @$todo{@gone};

	my $sock = tcp_server() or BAIL_OUT $!;
	my ($tmpdir, $for_destroy) = tmpdir();
	my ($out, $err) = map { "$tmpdir/std$_.log" } qw(out err);
	my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
	my $td = start_script($cmd, undef, { 3 => $sock });
	my ($h, $p) = tcp_host_port($sock);
	local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = "http://$h:$p";
	while (($ibx_name, $urls) = each %$todo) {
		Plack::Test::ExternalServer::test_psgi(client => $client);
	}
}

done_testing();
