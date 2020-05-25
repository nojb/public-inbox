# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Builder Plack::Test URI::Escape);
require_mods(@mods);
use_ok $_ foreach @mods;
use_ok 'PublicInbox::WWW';
use PublicInbox::Import;
use PublicInbox::Git;
use PublicInbox::Config;
use PublicInbox::Eml;
use_ok 'PublicInbox::WwwAttach';
my $config = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=$addr
$cfgpfx.inboxdir=$maindir
EOF
my $git = PublicInbox::Git->new($maindir);
my $im = PublicInbox::Import->new($git, 'test', $addr);
$im->init_bare;

{
	my $qp = "abcdef=g\n==blah\n";
	my $b64 = "b64\xde\xad\xbe\xef\n";
	my $txt = "plain\ntext\npass\nthrough\n";
	my $dot = "dotfile\n";
	$im->add(eml_load('t/psgi_attach.eml'));
	$im->add(eml_load('t/data/message_embed.eml'));
	$im->done;

	my $www = PublicInbox::WWW->new($config);
	test_psgi(sub { $www->call(@_) }, sub {
		my ($cb) = @_;
		my $res;
		$res = $cb->(GET('/test/Z%40B/'));
		my @href = ($res->content =~ /^href="([^"]+)"/gms);
		@href = grep(/\A[\d\.]+-/, @href);
		is_deeply([qw(1-queue-pee 2-bayce-sixty-four 3-noop.txt
				4-a.txt)],
			\@href, 'attachment links generated');

		$res = $cb->(GET('/test/Z%40B/1-queue-pee'));
		my $qp_res = $res->content;
		ok(length($qp_res) >= length($qp), 'QP length is close');
		like($qp_res, qr/\n\z/s, 'trailing newline exists');
		# is(index($qp_res, $qp), 0, 'QP trailing newline is there');
		$qp_res =~ s/\r\n/\n/g;
		is(index($qp_res, $qp), 0, 'QP trailing newline is there');

		$res = $cb->(GET('/test/Z%40B/2-base-sixty-four'));
		is(quotemeta($res->content), quotemeta($b64),
			'Base64 matches exactly');

		$res = $cb->(GET('/test/Z%40B/3-noop.txt'));
		my $txt_res = $res->content;
		ok(length($txt_res) >= length($txt),
			'plain text almost matches');
		like($txt_res, qr/\n\z/s, 'trailing newline exists in text');
		is(index($txt_res, $txt), 0, 'plain text not truncated');

		$res = $cb->(GET('/test/Z%40B/4-a.txt'));
		my $dot_res = $res->content;
		ok(length($dot_res) >= length($dot), 'dot almost matches');
		$res = $cb->(GET('/test/Z%40B/4-any-filename.txt'));
		is($res->content, $dot_res, 'user-specified filename is OK');

		my $mid = '20200418222508.GA13918@dcvr';
		my $irt = '20200418222020.GA2745@dcvr';
		$res = $cb->(GET("/test/$mid/"));
		unlike($res->content, qr! multipart/mixed, Size: 0 bytes!,
			'0-byte download not offered');
		like($res->content, qr/\bhref="2-embed2x\.eml"/s,
			'href to message/rfc822 attachment visible');
		like($res->content, qr/\bhref="2\.1\.2-test\.eml"/s,
			'href to nested message/rfc822 attachment visible');

		$res = $cb->(GET("/test/$mid/2-embed2x.eml"));
		my $eml = PublicInbox::Eml->new(\($res->content));
		is_deeply([ $eml->header_raw('Message-ID') ], [ "<$irt>" ],
			'got attached eml');
		my @subs = $eml->subparts;
		is(scalar(@subs), 2, 'attachment had 2 subparts');
		like($subs[0]->body_str, qr/^testing embedded message\n*\z/sm,
			'1st attachment is as expected');
		is($subs[1]->header('Content-Type'), 'message/rfc822',
			'2nd attachment is as expected');

		$res = $cb->(GET("/test/$mid/2.1.2-test.eml"));
		$eml = PublicInbox::Eml->new(\($res->content));
		is_deeply([ $eml->header_raw('Message-ID') ],
			[ '<20200418214114.7575-1-e@yhbt.net>' ],
			'nested eml retrieved');
	});
}
done_testing();
