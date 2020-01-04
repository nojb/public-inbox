#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Config; # this relies on PI_CONFIG // ~/.public-inbox/config
use PublicInbox::WWW;
my @psgi = qw(HTTP::Request::Common Plack::Test URI::Escape Plack::Builder);
require_mods(qw(DBD::SQLite Search::Xapian), @psgi);
use_ok($_) for @psgi;
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
		'6aa8857a11/s/?b=protocol.c', # TODO: i/, w/ instead of a/ b/
		'96f1c7f/s/', # TODO: b=contrib/completion/git-completion.bash
		'b76f2c0/s/?b=po/zh_CN.po',
	],
};

my ($ibx, $urls);
my $client = sub {
	my ($cb) = @_;
	for (@$urls) {
		my $url = "/$ibx/$_";
		my $res = $cb->(GET($url));
		is($res->code, 200, $url);
		next if $res->code == 200;
		# diag $res->content;
		diag "$url failed";
	}
};

while (($ibx, $urls) = each %$todo) {
	SKIP: {
		if (!$cfg->lookup_name($ibx)) {
			skip("$ibx not configured", scalar(@$urls));
		}
		test_psgi($app, $client);
	}
}

done_testing();
1;
