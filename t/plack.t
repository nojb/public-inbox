#!perl -w
# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
my $psgi = "./examples/public-inbox.psgi";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
require_mods(@mods);
foreach my $mod (@mods) { use_ok $mod; }
ok(-f $psgi, "psgi example file found");
my $pfx = 'http://example.com/test';
my $eml = eml_load('t/iso-2202-jp.eml');
# ensure successful message deliveries
my $ibx = create_inbox('test-1', sub {
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

local $ENV{PI_CONFIG} = "$ibx->{inboxdir}/pi_config";
my $app = require $psgi;
test_psgi($app, sub {
	my ($cb) = @_;
	foreach my $u (qw(robots.txt favicon.ico .well-known/foo)) {
		my $res = $cb->(GET("http://example.com/$u"));
		is($res->code, 404, "$u is missing");
	}
});

test_psgi($app, sub {
	my ($cb) = @_;
	my $res = $cb->(GET('http://example.com/test/crlf@example.com/'));
	is($res->code, 200, 'retrieved CRLF as HTML');
	like($res->content, qr/mailto:me\@example/, 'no %40, per RFC 6068');
	unlike($res->content, qr/\r/, 'no CR in HTML');
	$res = $cb->(GET('http://example.com/test/crlf@example.com/raw'));
	is($res->code, 200, 'retrieved CRLF raw');
	like($res->content, qr/\r/, 'CR preserved in raw message');
	$res = $cb->(GET('http://example.com/test/bogus@example.com/raw'));
	is($res->code, 404, 'missing /raw is 404');
});

# redirect with newsgroup
test_psgi($app, sub {
	my ($cb) = @_;
	my $from = 'http://example.com/inbox.test';
	my $to = 'http://example.com/test/';
	my $res = $cb->(GET($from));
	is($res->code, 301, 'newsgroup name is permanent redirect');
	is($to, $res->header('Location'), 'redirect location matches');
	$from .= '/';
	is($res->code, 301, 'newsgroup name/ is permanent redirect');
	is($to, $res->header('Location'), 'redirect location matches');
});

# redirect with trailing /
test_psgi($app, sub {
	my ($cb) = @_;
	my $from = 'http://example.com/test';
	my $to = "$from/";
	my $res = $cb->(GET($from));
	is(301, $res->code, 'is permanent redirect');
	is($to, $res->header('Location'),
		'redirect location matches with trailing slash');
});

foreach my $t (qw(t T)) {
	test_psgi($app, sub {
		my ($cb) = @_;
		my $u = $pfx . "/blah\@example.com/$t";
		my $res = $cb->(GET($u));
		is(301, $res->code, "redirect for missing /");
		my $location = $res->header('Location');
		like($location, qr!/\Q$t\E/#u\z!,
			'redirected with missing /');
	});
}
foreach my $t (qw(f)) {
	test_psgi($app, sub {
		my ($cb) = @_;
		my $u = $pfx . "/blah\@example.com/$t";
		my $res = $cb->(GET($u));
		is(301, $res->code, "redirect for legacy /f");
		my $location = $res->header('Location');
		like($location, qr!/blah\@example\.com/\z!,
			'redirected with missing /');
	});
}

test_psgi($app, sub {
	my ($cb) = @_;
	my $atomurl = 'http://example.com/test/new.atom';
	my $res = $cb->(GET('http://example.com/test/new.html'));
	is(200, $res->code, 'success response received');
	like($res->content, qr!href="new\.atom"!,
		'atom URL generated');
	like($res->content, qr!href="blah\@example\.com/"!,
		'index generated');
	like($res->content, qr!1993-10-02!, 'date set');
});

test_psgi($app, sub {
	my ($cb) = @_;
	my $res = $cb->(GET($pfx . '/atom.xml'));
	is(200, $res->code, 'success response received for atom');
	my $body = $res->content;
	like($body, qr!link\s+href="\Q$pfx\E/blah\@example\.com/"!s,
		'atom feed generated correct URL');
	like($body, qr/<title>test for public-inbox/,
		"set title in XML feed");
	like($body, qr/zzzzzz/, 'body included');
	$res = $cb->(GET($pfx . '/description'));
	like($res->content, qr/test for public-inbox/, 'got description');
});

test_psgi($app, sub {
	my ($cb) = @_;
	my $path = '/blah@example.com/';
	my $res = $cb->(GET($pfx . $path));
	is(200, $res->code, "success for $path");
	my $html = $res->content;
	like($html, qr!<title>hihi - Me</title>!, 'HTML returned');
	like($html, qr!<a\nhref="raw"!s, 'raw link present');
	like($html, qr!&gt; quoted text!s, 'quoted text inline');

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
});

test_psgi($app, sub {
	my ($cb) = @_;
	my $res = $cb->(GET($pfx . '/blah@example.com/raw'));
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
	chomp(my $body = $res->content);
	my $raw = PublicInbox::Eml->new(\$body);
	is($raw->body_raw, $eml->body_raw, 'ISO-2022-JP body unmodified');

	$res = $cb->(GET($pfx . '/blah@example.com/t.mbox.gz'));
	is(501, $res->code, '501 when overview missing');
	like($res->content, qr!\bOverview\b!, 'overview omission noted');
});

# legacy redirects
foreach my $t (qw(m f)) {
	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET($pfx . "/$t/blah\@example.com.txt"));
		is(301, $res->code, "redirect for old $t .txt link");
		my $location = $res->header('Location');
		like($location, qr!/blah\@example\.com/raw\z!,
			".txt redirected to /raw");
	});
}

my %umap = (
	'm' => '',
	'f' => '',
	't' => 't/',
);
while (my ($t, $e) = each %umap) {
	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET($pfx . "/$t/blah\@example.com.html"));
		is(301, $res->code, "redirect for old $t .html link");
		my $location = $res->header('Location');
		like($location,
			qr!/blah\@example\.com/$e(?:#u)?\z!,
			".html redirected to new location");
	});
}
foreach my $sfx (qw(mbox mbox.gz)) {
	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET($pfx . "/t/blah\@example.com.$sfx"));
		is(301, $res->code, 'redirect for old thread link');
		my $location = $res->header('Location');
		like($location,
		     qr!/blah\@example\.com/t\.mbox(?:\.gz)?\z!,
		     "$sfx redirected to /mbox.gz");
	});
}
test_psgi($app, sub {
	my ($cb) = @_;
	# for a while, we used to support /$INBOX/$X40/
	# when we "compressed" long Message-IDs to SHA-1
	# Now we're stuck supporting them forever :<
	foreach my $path ('f2912279bd7bcd8b7ab3033234942d58746d56f7') {
		my $from = "http://example.com/test/$path/";
		my $res = $cb->(GET($from));
		is(301, $res->code, 'is permanent redirect');
		like($res->header('Location'),
			qr!/test/blah\@example\.com/!,
			'redirect from x40 MIDs works');
	}
});

# dumb HTTP clone/fetch support
test_psgi($app, sub {
	my ($cb) = @_;
	my $path = '/test/info/refs';
	my $req = HTTP::Request->new('GET' => $path);
	my $res = $cb->($req);
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
});

# things which should fail
test_psgi($app, sub {
	my ($cb) = @_;

	my $res = $cb->(PUT('/'));
	is(405, $res->code, 'no PUT to / allowed');
	$res = $cb->(PUT('/test/'));
	is(405, $res->code, 'no PUT /$INBOX allowed');

	# TODO
	# $res = $cb->(GET('/'));
});

done_testing();
