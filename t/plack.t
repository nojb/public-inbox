# Copyright (C) 2014-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
my $psgi = "./examples/public-inbox.psgi";
my $tmpdir = tempdir('pi-plack-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $pi_config = "$tmpdir/config";
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for plack.t" if $@;
}
use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Git';
my @ls;

foreach my $mod (@mods) { use_ok $mod; }
{
	ok(-f $psgi, "psgi example file found");
	is(0, system(qw(git init -q --bare), $maindir), "git init (main)");
	open my $fh, '>', "$maindir/description" or die "open: $!\n";
	print $fh "test for public-inbox\n";
	close $fh or die "close: $!\n";
	my %cfg = (
		"$cfgpfx.address" => $addr,
		"$cfgpfx.inboxdir" => $maindir,
		"$cfgpfx.url" => 'http://example.com/test/',
		"$cfgpfx.newsgroup" => 'inbox.test',
	);
	while (my ($k,$v) = each %cfg) {
		is(0, system(qw(git config --file), $pi_config, $k, $v),
			"setup $k");
	}

	# ensure successful message delivery
	{
		my $mime = Email::MIME->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <blah\@example.com>
Subject: hihi
Date: Fri, 02 Oct 1993 00:00:00 +0000

zzzzzz
EOF
		my $git = PublicInbox::Git->new($maindir);
		my $im = PublicInbox::Import->new($git, 'test', $addr);
		$im->add($mime);
		$im->done;
		my $rev = `git --git-dir="$maindir" rev-list HEAD`;
		like($rev, qr/\A[a-f0-9]{40}/, "good revision committed");
		@ls = `git --git-dir="$maindir" ls-tree -r --name-only HEAD`;
		chomp @ls;
	}
	my $app = eval {
		local $ENV{PI_CONFIG} = $pi_config;
		require $psgi;
	};

	test_psgi($app, sub {
		my ($cb) = @_;
		foreach my $u (qw(robots.txt favicon.ico .well-known/foo)) {
			my $res = $cb->(GET("http://example.com/$u"));
			is($res->code, 404, "$u is missing");
		}
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

	my $pfx = 'http://example.com/test';
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
	});

	test_psgi($app, sub {
		my ($cb) = @_;
		my $path = '/blah@example.com/';
		my $res = $cb->(GET($pfx . $path));
		is(200, $res->code, "success for $path");
		like($res->content, qr!<title>hihi - Me</title>!,
			"HTML returned");

		$path .= 'f/';
		$res = $cb->(GET($pfx . $path));
		is(301, $res->code, "redirect for $path");
		my $location = $res->header('Location');
		like($location, qr!/blah\@example\.com/\z!,
			'/$MESSAGE_ID/f/ redirected to /$MESSAGE_ID/');
	});

	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET($pfx . '/blah@example.com/raw'));
		is(200, $res->code, 'success response received for /*/raw');
		like($res->content, qr!^From !sm, "mbox returned");
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
		foreach my $path (@ls) {
			$path =~ tr!/!!d;
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
}

done_testing();
