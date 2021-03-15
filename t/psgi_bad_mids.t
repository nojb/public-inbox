#!perl -w
# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Config;
my @mods = qw(DBD::SQLite HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder);
require_git 2.6;
require_mods(@mods);
use_ok($_) for @mods;
use_ok 'PublicInbox::WWW';
my $msgs = <<'';
F1V5OR6NMF.3M649JTLO9IXD@tux.localdomain/hehe1"'<foo
F1V5NB0PTU.3U0DCVGAJ750Z@tux.localdomain"'<>/foo
F1V5NB0PTU.3U0DCVGAJ750Z@tux&.ampersand
F1V5MIHGCU.2ABINKW6WBE8N@tux.localdomain/raw
F1V5LF9D9C.2QT5PGXZQ050E@tux.localdomain/t.atom
F1V58X3CMU.2DCCVAKQZGADV@tux.localdomain/../../../../foo
F1TVKINT3G.2S6I36MXMHYG6@tux.localdomain" onclick="alert(1)"

my @mids = split(/\n/, $msgs);
my $ibx = create_inbox 'bad-mids', version => 2, indexlevel => 'basic', sub {
	my ($im) = @_;
	my $i = 0;
	for my $mid (@mids) {
		$im->add(PublicInbox::Eml->new(<<"")) or BAIL_OUT;
Subject: test
Message-ID: <$mid>
From: a\@example.com
To: b\@example.com
Date: Fri, 02 Oct 1993 00:00:0$i +0000

		$i++;
	}
};

my $cfgpfx = "publicinbox.bad-mids";
my $cfg = <<EOF;
$cfgpfx.address=$ibx->{-primary_address}
$cfgpfx.inboxdir=$ibx->{inboxdir}
EOF
my $config = PublicInbox::Config->new(\$cfg);
my $www = PublicInbox::WWW->new($config);
test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	my $res = $cb->(GET('/bad-mids/'));
	is($res->code, 200, 'got 200 OK listing');
	my $raw = $res->content;
	foreach my $mid (@mids) {
		ok(index($raw, $mid) < 0, "escaped $mid");
	}

	my (@xmids) = ($raw =~ m!\bhref="([^"]+)/t\.mbox\.gz"!sg);
	is(scalar(@xmids), scalar(@mids),
		'got escaped links to all messages');

	@xmids = reverse @xmids;
	my %uxs = ( gt => '>', lt => '<' );
	foreach my $i (0..$#xmids) {
		my $uri = $xmids[$i];
		$uri =~ s/&#([0-9]+);/sprintf("%c", $1)/sge;
		$uri =~ s/&(lt|gt);/$uxs{$1}/sge;
		$res = $cb->(GET("/bad-mids/$uri/raw"));
		is($res->code, 200, 'got 200 OK raw message '.$uri);
		like($res->content, qr/Message-ID: <\Q$mids[$i]\E>/s,
			'retrieved correct message');
	}
});

done_testing;
