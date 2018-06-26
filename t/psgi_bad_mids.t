# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use PublicInbox::MIME;
use PublicInbox::Config;
use PublicInbox::WWW;
my @mods = qw(DBD::SQLite Search::Xapian HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for psgi_bad_mids.t" if $@;
}
use_ok($_) for @mods;
use_ok 'PublicInbox::V2Writable';
my $mainrepo = tempdir('pi-bad-mids-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $cfgpfx = "publicinbox.bad-mids";
my $ibx = {
	mainrepo => $mainrepo,
	name => 'bad-mids',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $im = PublicInbox::V2Writable->new($ibx, 1);
$im->{parallel} = 0;

my $msgs = <<'';
F1V5OR6NMF.3M649JTLO9IXD@tux.localdomain/hehe1"'<foo
F1V5NB0PTU.3U0DCVGAJ750Z@tux.localdomain"'<>/foo
F1V5MIHGCU.2ABINKW6WBE8N@tux.localdomain/raw
F1V5LF9D9C.2QT5PGXZQ050E@tux.localdomain/t.atom
F1V58X3CMU.2DCCVAKQZGADV@tux.localdomain/../../../../foo
F1TVKINT3G.2S6I36MXMHYG6@tux.localdomain" onclick="alert(1)"

my @mids = split(/\n/, $msgs);
my $i = 0;
foreach my $mid (@mids) {
	my $data = << "";
Subject: test
Message-ID: <$mid>
From: a\@example.com
To: b\@example.com
Date: Fri, 02 Oct 1993 00:00:0$i +0000


	my $mime = PublicInbox::MIME->new(\$data);
	ok($im->add($mime), "added $mid");
	$i++
}
$im->done;

my $cfg = {
	"$cfgpfx.address" => $ibx->{-primary_address},
	"$cfgpfx.mainrepo" => $mainrepo,
};
my $config = PublicInbox::Config->new($cfg);
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
	foreach my $i (0..$#xmids) {
		$res = $cb->(GET("/bad-mids/$xmids[$i]/raw"));
		is($res->code, 200, 'got 200 OK raw message');
		like($res->content, qr/Message-ID: <\Q$mids[$i]\E>/s,
			'retrieved correct message');
	}
});

done_testing();

1;
