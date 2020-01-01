# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
require_mods(@mods);
use_ok $_ foreach @mods;
use_ok 'PublicInbox::WwwStatic';

my $app = sub {
	my $ws = PublicInbox::WwwStatic->new(docroot => $tmpdir, @_);
	sub { $ws->call(shift) };
};

test_psgi($app->(), sub {
	my $cb = shift;
	my $res = $cb->(GET('/'));
	is($res->code, 404, '404 on "/" by default');
	open my $fh, '>', "$tmpdir/index.html" or die;
	print $fh 'hi' or die;
	close $fh or die;
	$res = $cb->(GET('/'));
	is($res->code, 200, '200 with index.html');
	is($res->content, 'hi', 'default index.html returned');
	$res = $cb->(HEAD('/'));
	is($res->code, 200, '200 on HEAD /');
	is($res->content, '', 'no content');
	is($res->header('Content-Length'), '2', 'content-length set');
	like($res->header('Content-Type'), qr!^text/html\b!,
		'content-type is html');
});

test_psgi($app->(autoindex => 1, index => []), sub {
	my $cb = shift;
	my $res = $cb->(GET('/'));
	my $updir = 'href="../">../</a>';
	is($res->code, 200, '200 with autoindex default');
	my $ls = $res->content;
	like($ls, qr/index\.html/, 'got listing with index.html');
	ok(index($ls, $updir) < 0, 'no updir at /');
	mkdir("$tmpdir/dir") or die;
	rename("$tmpdir/index.html", "$tmpdir/dir/index.html") or die;

	$res = $cb->(GET('/dir/'));
	is($res->code, 200, '200 with autoindex for dir/');
	$ls = $res->content;
	ok(index($ls, $updir) > 0, 'updir at /dir/');

	for my $up (qw(/../ .. /dir/.. /dir/../)) {
		is($cb->(GET($up))->code, 403, "`$up' traversal rejected");
	}

	$res = $cb->(GET('/dir'));
	is($res->code, 302, '302 w/o slash');
	like($res->header('Location'), qr!://[^/]+/dir/\z!,
		'redirected w/ slash');

	rename("$tmpdir/dir/index.html", "$tmpdir/dir/foo") or die;
	link("$tmpdir/dir/foo", "$tmpdir/dir/foo.gz") or die;
	$res = $cb->(GET('/dir/'));
	unlike($res->content, qr/>foo\.gz</,
		'.gz file hidden if mtime matches uncompressed');
	like($res->content, qr/>foo</, 'uncompressed foo shown');

	$res = $cb->(GET('/dir/foo/bar'));
	is($res->code, 404, 'using file as dir fails');

	unlink("$tmpdir/dir/foo") or die;
	$res = $cb->(GET('/dir/'));
	like($res->content, qr/>foo\.gz</,
		'.gz shown when no uncompressed version exists');

	open my $fh, '>', "$tmpdir/dir/foo" or die;
	print $fh "uncompressed\n" or die;
	close $fh or die;
	utime(0, 0, "$tmpdir/dir/foo") or die;
	$res = $cb->(GET('/dir/'));
	my $html = $res->content;
	like($html, qr/>foo</, 'uncompressed foo shown');
	like($html, qr/>foo\.gz</, 'gzipped foo shown on mtime mismatch');

	$res = $cb->(GET('/dir/foo'));
	is($res->content, "uncompressed\n",
		'got uncompressed on mtime mismatch');

	utime(0, 0, "$tmpdir/dir/foo.gz") or die;
	my $get = GET('/dir/foo');
	$get->header('Accept-Encoding' => 'gzip');
	$res = $cb->($get);
	is($res->content, "hi", 'got compressed on mtime match');
});

done_testing();
