#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
my $psgi = "./examples/public-inbox.psgi";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
require_mods(@mods);
foreach my $mod (@mods) { use_ok $mod; }
ok(-f $psgi, "psgi example file found");
my ($tmpdir, $for_destroy) = tmpdir();
my $pfx = 'http://example.com/test';
my $eml = eml_load('t/iso-2202-jp.eml');
# ensure successful message deliveries
my $ibx = create_inbox('u8-2', sub {
	my ($im, $ibx) = @_;
	my $addr = $ibx->{-primary_address};
	$im->add($eml) or xbail '->add';
	$eml->header_set('Content-Type',
		"text/plain; charset=\rso\rb\0gus\rithurts");
	$eml->header_set('Message-ID', '<broken@example.com>');
	$im->add($eml) or xbail '->add';
	$im->add(PublicInbox::Eml->new(<<EOF)) or xbail '->add';
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <blah\@example.com>
Subject: hihi
Date: Fri, 02 Oct 1993 00:00:00 +0000
Content-Type: text/plain; charset=iso-8859-1

> quoted text
zzzzzz
EOF
	# multipart with two text bodies
	$im->add(eml_load('t/plack-2-txt-bodies.eml')) or BAIL_OUT '->add';

	# multipart with attached patch + filename
	$im->add(eml_load('t/plack-attached-patch.eml')) or BAIL_OUT '->add';

	$im->add(eml_load('t/data/attached-mbox-with-utf8.eml')) or xbail 'add';

	# multipart collapsed to single quoted-printable text/plain
	$im->add(eml_load('t/plack-qp.eml')) or BAIL_OUT '->add';
	my $crlf = <<EOF;
From: Me
  <me\@example.com>
To: $addr
Message-Id: <crlf\@example.com>
Subject: carriage
  return
  in
  long
  subject
Date: Fri, 02 Oct 1993 00:00:00 +0000

:(
EOF
	$crlf =~ s/\n/\r\n/sg;
	$im->add(PublicInbox::Eml->new($crlf)) or BAIL_OUT '->add';

	open my $fh, '>', "$ibx->{inboxdir}/description" or BAIL_OUT "open: $!";
	print $fh "test for public-inbox\n" or BAIL_OUT;
	close $fh or BAIL_OUT "close: $!";
	open $fh, '>', "$ibx->{inboxdir}/pi_config";
	print $fh <<EOF or BAIL_OUT;
[publicinbox "test"]
	inboxdir = $ibx->{inboxdir}
	newsgroup = inbox.test
	address = $addr
	url = $pfx/
EOF
	close $fh or BAIL_OUT "close: $!";
});

my $env = { PI_CONFIG => "$ibx->{inboxdir}/pi_config", TMPDIR => $tmpdir };
local @ENV{keys %$env} = values %$env;
my $c1 = sub {
	my ($cb) = @_;
	my $uri = $ENV{PLACK_TEST_EXTERNALSERVER_URI} // 'http://example.com';
	$pfx = "$uri/test";

	foreach my $u (qw(robots.txt favicon.ico .well-known/foo)) {
		my $res = $cb->(GET("$uri/$u"));
		is($res->code, 404, "$u is missing");
	}

	my $res = $cb->(GET("$uri/test/crlf\@example.com/"));
	is($res->code, 200, 'retrieved CRLF as HTML');
	like($res->content, qr/mailto:me\@example/, 'no %40, per RFC 6068');
	unlike($res->content, qr/\r/, 'no CR in HTML');
	$res = $cb->(GET("$uri/test/crlf\@example.com/raw"));
	is($res->code, 200, 'retrieved CRLF raw');
	like($res->content, qr/\r/, 'CR preserved in raw message');
	$res = $cb->(GET("$uri/test/bogus\@example.com/raw"));
	is($res->code, 404, 'missing /raw is 404');

	# redirect with newsgroup
	my $from = "$uri/inbox.test";
	my $to = "http://example.com/test/";
	$res = $cb->(GET($from));
	is($res->code, 301, 'newsgroup name is permanent redirect');
	is($to, $res->header('Location'), 'redirect location matches');
	$from .= '/';
	is($res->code, 301, 'newsgroup name/ is permanent redirect');
	is($to, $res->header('Location'), 'redirect location matches');

	# redirect with trailing /
	$from = "$uri/test";
	$to = "$from/";
	$res = $cb->(GET($from));
	is(301, $res->code, 'is permanent redirect');
	is($to, $res->header('Location'),
		'redirect location matches with trailing slash');

	for my $t (qw(T t)) {
		my $u = $pfx . "/blah\@example.com/$t";
		$res = $cb->(GET($u));
		is(301, $res->code, "redirect for missing /");
		my $location = $res->header('Location');
		like($location, qr!/\Q$t\E/#u\z!,
			'redirected with missing /');
	}

	for my $t (qw(f)) { # legacy redirect
		my $u = $pfx . "/blah\@example.com/$t";
		$res = $cb->(GET($u));
		is(301, $res->code, "redirect for legacy /f");
		my $location = $res->header('Location');
		like($location, qr!/blah\@example\.com/\z!,
			'redirected with missing /');
	}

	my $atomurl = "$uri/test/new.atom";
	$res = $cb->(GET("$uri/test/new.html"));
	is(200, $res->code, 'success response received');
	like($res->content, qr!href="new\.atom"!,
		'atom URL generated');
	like($res->content, qr!href="blah\@example\.com/"!,
		'index generated');
	like($res->content, qr!1993-10-02!, 'date set');

	$res = $cb->(GET($pfx . '/atom.xml'));
	is(200, $res->code, 'success response received for atom');
	my $body = $res->content;
	like($body, qr!link\s+href="\Q$pfx\E/blah\@example\.com/"!s,
		'atom feed generated correct URL');
	like($body, qr/<title>test for public-inbox/,
		"set title in XML feed");
	like($body, qr/zzzzzz/, 'body included');
	$res = $cb->(GET($pfx . '/description'));
	like($res->content, qr/test for public-inbox/, 'got description');

	my $path = '/blah@example.com/';
	$res = $cb->(GET($pfx . $path));
	is(200, $res->code, "success for $path");
	my $html = $res->content;
	like($html, qr!\bhref="\Q../_/text/help/"!, 'help available');
	like($html, qr!<title>hihi - Me</title>!, 'HTML returned');
	like($html, qr!<a\nhref=raw!s, 'raw link present');
	like($html, qr!&gt; quoted text!s, 'quoted text inline');
	unlike($html, qr!thread overview!,
		'thread overview not shown w/o ->over');

	$path .= 'f/';
	$res = $cb->(GET($pfx . $path));
	is(301, $res->code, "redirect for $path");
	my $location = $res->header('Location');
	like($location, qr!/blah\@example\.com/\z!,
		'/$MESSAGE_ID/f/ redirected to /$MESSAGE_ID/');

	$res = $cb->(GET($pfx . '/multipart@example.com/'));
	like($res->content,
		qr/hi\n.*-- Attachment #2.*\nbye\n/s, 'multipart split');

	$res = $cb->(GET($pfx . '/patch@example.com/'));
	$html = $res->content;
	like($html, qr!see attached!, 'original body');
	like($html, qr!.*Attachment #2: foo&(?:amp|#38);\.patch --!,
		'parts split with filename');

	$res = $cb->(GET($pfx . '/qp@example.com/'));
	like($res->content, qr/\bhi = bye\b/, "HTML output decoded QP");

	$res = $cb->(GET($pfx . '/attached-mbox-with-utf8@example/'));
	like($res->content, qr/: Bj&#248;rn /, 'UTF-8 in mbox #1');
	like($res->content, qr/: j &#379;en/, 'UTF-8 in mbox #2');

	$res = $cb->(GET($pfx . '/blah@example.com/raw'));
	is(200, $res->code, 'success response received for /*/raw');
	like($res->content, qr!^From !sm, "mbox returned");
	is($res->header('Content-Type'), 'text/plain; charset=iso-8859-1',
		'charset from message used');

	$res = $cb->(GET($pfx . '/broken@example.com/raw'));
	is($res->header('Content-Type'), 'text/plain; charset=UTF-8',
		'broken charset ignored');

	$res = $cb->(GET($pfx . '/199707281508.AAA24167@hoyogw.example/raw'));
	is($res->header('Content-Type'), 'text/plain; charset=ISO-2022-JP',
		'ISO-2002-JP returned');
	chomp($body = $res->content);
	my $raw = PublicInbox::Eml->new(\$body);
	is($raw->body_raw, $eml->body_raw, 'ISO-2022-JP body unmodified');

	$res = $cb->(GET($pfx . '/blah@example.com/t.mbox.gz'));
	is(501, $res->code, '501 when overview missing');
	like($res->content, qr!\bOverview\b!, 'overview omission noted');

	# legacy redirects
	for my $t (qw(m f)) {
		$res = $cb->(GET($pfx . "/$t/blah\@example.com.txt"));
		is(301, $res->code, "redirect for old $t .txt link");
		$location = $res->header('Location');
		like($location, qr!/blah\@example\.com/raw\z!,
			".txt redirected to /raw");
	}

	my %umap = (
		'm' => '',
		'f' => '',
		't' => 't/',
	);
	while (my ($t, $e) = each %umap) {
		$res = $cb->(GET($pfx . "/$t/blah\@example.com.html"));
		is(301, $res->code, "redirect for old $t .html link");
		$location = $res->header('Location');
		like($location, qr!/blah\@example\.com/$e(?:#u)?\z!,
				".html redirected to new location");
	}

	for my $sfx (qw(mbox mbox.gz)) {
		$res = $cb->(GET($pfx . "/t/blah\@example.com.$sfx"));
		is(301, $res->code, 'redirect for old thread link');
		$location = $res->header('Location');
		like($location,
		     qr!/blah\@example\.com/t\.mbox(?:\.gz)?\z!,
		     "$sfx redirected to /mbox.gz");
	}

	# for a while, we used to support /$INBOX/$X40/
	# when we "compressed" long Message-IDs to SHA-1
	# Now we're stuck supporting them forever :<
	for my $path ('f2912279bd7bcd8b7ab3033234942d58746d56f7') {
		$from = "$uri/test/$path/";
		$res = $cb->(GET($from));
		is(301, $res->code, 'is permanent redirect');
		like($res->header('Location'),
			qr!/test/blah\@example\.com/!,
			'redirect from x40 MIDs works');
	}

	# dumb HTTP clone/fetch support
	$path = '/test/info/refs';
	my $req = HTTP::Request->new('GET' => $path);
	$res = $cb->($req);
	is(200, $res->code, 'refs readable');
	my $orig = $res->content;

	$req->header('Range', 'bytes=5-10');
	$res = $cb->($req);
	is(206, $res->code, 'got partial response');
	is($res->content, substr($orig, 5, 6), 'partial body OK');

	$req->header('Range', 'bytes=5-');
	$res = $cb->($req);
	is(206, $res->code, 'got partial another response');
	is($res->content, substr($orig, 5), 'partial body OK past end');


	# things which should fail
	$res = $cb->(PUT('/'));
	is(405, $res->code, 'no PUT to / allowed');
	$res = $cb->(PUT('/test/'));
	is(405, $res->code, 'no PUT /$INBOX allowed');
};
test_psgi(require $psgi, $c1);
test_httpd($env, $c1);
done_testing;
