# Copyright (C) 2017-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use IO::Uncompress::Gunzip qw(gunzip);
use PublicInbox::Eml;
use PublicInbox::Config;
use PublicInbox::Inbox;
use PublicInbox::InboxWritable;
use bytes (); # only for bytes::length
use PublicInbox::TestCommon;
my @mods = qw(DBD::SQLite Search::Xapian HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder);
require_mods(@mods);
use_ok($_) for (qw(HTTP::Request::Common Plack::Test));
use_ok 'PublicInbox::WWW';
use_ok 'PublicInbox::SearchIdx';
my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{TZ} = 'UTC';

my $ibx = PublicInbox::Inbox->new({
	inboxdir => $tmpdir,
	address => 'git@vger.kernel.org',
	name => 'test',
});
$ibx = PublicInbox::InboxWritable->new($ibx);
$ibx->init_inbox(1);
my $im = $ibx->importer(0);
my $digits = '10010260936330';
my $ua = 'Pine.LNX.4.10';
my $mid = "$ua.$digits.2460-100000\@penguin.transmeta.com";

# n.b. these headers are not properly RFC2047-encoded
my $mime = PublicInbox::Eml->new(<<EOF);
Subject: test Ævar
Message-ID: <$mid>
From: Ævar Arnfjörð Bjarmason <avarab\@example>
To: git\@vger.kernel.org

EOF
$im->add($mime);

$im->add(PublicInbox::Eml->new(<<""));
Message-ID: <reply\@asdf>
From: replier <r\@example.com>
In-Reply-To: <$mid>
Subject: mismatch

$mime = PublicInbox::Eml->new(<<'EOF');
Subject:
Message-ID: <blank-subject@example.com>
From: blank subject <blank-subject@example.com>
To: git@vger.kernel.org

EOF
$im->add($mime);

$mime = PublicInbox::Eml->new(<<'EOF');
Message-ID: <no-subject-at-all@example.com>
From: no subject at all <no-subject-at-all@example.com>
To: git@vger.kernel.org

EOF
$im->add($mime);

$im->done;
PublicInbox::SearchIdx->new($ibx, 1)->index_sync;

my $cfgpfx = "publicinbox.test";
my $cfg = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=git\@vger.kernel.org
$cfgpfx.inboxdir=$tmpdir
EOF
my $www = PublicInbox::WWW->new($cfg);
test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	my ($html, $res);
	my $approxidate = 'now';
	for my $req ('/test/?q=%C3%86var', '/test/?q=%25C3%2586var') {
		$res = $cb->(GET($req."+d:..$approxidate"));
		$html = $res->content;
		like($html, qr/<title>&#198;var d:\.\.\Q$approxidate\E/,
			'HTML escaped in title, "d:..$APPROXIDATE" preserved');
		my @res = ($html =~ m/\?q=(.+var)\+d:\.\.\Q$approxidate\E/g);
		ok(scalar(@res), 'saw query strings');
		my %uniq = map { $_ => 1 } @res;
		is(1, scalar keys %uniq, 'all query values identical in HTML');
		is('%C3%86var', (keys %uniq)[0], 'matches original query');
		ok(index($html, 'by &#198;var Arnfj&#246;r&#240; Bjarmason')
			>= 0, "displayed Ævar's name properly in HTML");
		like($html, qr/download mbox\.gz: .*?"full threads"/s,
			'"full threads" download option shown');
	}
	like($html, qr/Initial query\b.*?returned no.results, used:.*instead/s,
		'noted retry on double-escaped query {-uxs_retried}');

	my $warn = [];
	local $SIG{__WARN__} = sub { push @$warn, @_ };
	$res = $cb->(GET('/test/?q=s:test&l=5e'));
	is($res->code, 200, 'successful search result');
	is_deeply([], $warn, 'no warnings from non-numeric comparison');

	$res = $cb->(POST('/test/?q=s:bogus&x=m'));
	is($res->code, 404, 'failed search result gives 404');
	is_deeply([], $warn, 'no warnings');

	my $mid_re = qr/\Q$mid\E/o;
	while (length($digits) > 8) {
		$res = $cb->(GET("/test/$ua.$digits/"));
		is($res->code, 300, 'partial match found while truncated');
		like($res->content, qr/\b1 partial match found\b/);
		like($res->content, $mid_re, 'found mid in response');
		chop($digits);
	}

	$res = $cb->(GET('/test/'));
	$html = $res->content;
	like($html, qr/\bhref="no-subject-at-all[^>]+>\(no subject\)</,
		'subject-less message linked from "/$INBOX/"');
	like($html, qr/\bhref="blank-subject[^>]+>\(no subject\)</,
		'blank subject message linked from "/$INBOX/"');
	like($html, qr/test &#198;var/,
		"displayed Ævar's name properly in topic view");

	$res = $cb->(GET('/test/?q=tc:git'));
	like($html, qr/\bhref="no-subject-at-all[^>]+>\(no subject\)</,
		'subject-less message linked from "/$INBOX/?q=..."');
	like($html, qr/\bhref="blank-subject[^>]+>\(no subject\)</,
		'blank subject message linked from "/$INBOX/?q=..."');
	$res = $cb->(GET('/test/no-subject-at-all@example.com/raw'));
	like($res->header('Content-Disposition'),
		qr/filename=no-subject\.txt/);
	$res = $cb->(GET('/test/no-subject-at-all@example.com/t.mbox.gz'));
	like($res->header('Content-Disposition'),
		qr/filename=no-subject\.mbox\.gz/);

	# "full threads" mbox.gz download
	$res = $cb->(POST("/test/?q=s:test+d:..$approxidate&x=m&t"));
	is($res->code, 200, 'successful mbox download with threads');
	gunzip(\($res->content) => \(my $before));
	is_deeply([ "Message-ID: <$mid>\n", "Message-ID: <reply\@asdf>\n" ],
		[ grep(/^Message-ID:/m, split(/^/m, $before)) ],
		'got full thread');

	# clobber has_threadid to emulate old versions:
	{
		my $sidx = PublicInbox::SearchIdx->new($ibx, 0);
		my $xdb = $sidx->idx_acquire;
		$xdb->set_metadata('has_threadid', '0');
		$sidx->idx_release;
	}
	$cfg->each_inbox(sub { delete $_[0]->{search} });
	$res = $cb->(GET('/test/?q=s:test'));
	is($res->code, 200, 'successful search w/o has_threadid');
	unlike($html, qr/download mbox\.gz: .*?"full threads"/s,
		'"full threads" download option not shown w/o has_threadid');

	# in case somebody uses curl to bypass <form>
	$res = $cb->(POST("/test/?q=s:test+d:..$approxidate&x=m&t"));
	is($res->code, 200, 'successful mbox download w/ threads');
	gunzip(\($res->content) => \(my $after));
	isnt($before, $after);
});

done_testing();
