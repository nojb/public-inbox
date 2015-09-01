# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
use Cwd;
use IPC::Run qw/run/;
my $psgi = "examples/public-inbox.psgi";
my $mda = "blib/script/public-inbox-mda";
my $tmpdir = tempdir(CLEANUP => 1);
my $home = "$tmpdir/pi-home";
my $pi_home = "$home/.public-inbox";
my $pi_config = "$pi_home/config";
my $maindir = "$tmpdir/main.git";
my $main_bin = getcwd()."/t/main-bin";
my $main_path = "$main_bin:$ENV{PATH}"; # for spamc ham mock
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my $failbox = "$home/fail.mbox";
local $ENV{PI_EMERGENCY} = $failbox;

our $have_plack;
eval {
	require Plack::Request;
	eval 'use Plack::Test; use HTTP::Request::Common';
	$have_plack = 1;
};
SKIP: {
	skip 'Plack not installed', 1 unless $have_plack;
	ok(-f $psgi, "psgi example file found");
	ok(-x "$main_bin/spamc",
		"spamc ham mock found (run in top of source tree");
	ok(-x $mda, "$mda is executable");
	is(1, mkdir($home, 0755), "setup ~/ for testing");
	is(1, mkdir($pi_home, 0755), "setup ~/.public-inbox");
	is(0, system(qw(git init -q --bare), $maindir), "git init (main)");
	open my $fh, '>', "$maindir/description" or die "open: $!\n";
	print $fh "test for public-inbox\n";
	close $fh or die "close: $!\n";
	my %cfg = (
		"$cfgpfx.address" => $addr,
		"$cfgpfx.mainrepo" => $maindir,
	);
	while (my ($k,$v) = each %cfg) {
		is(0, system(qw(git config --file), $pi_config, $k, $v),
			"setup $k");
	}

	local $ENV{HOME} = $home;
	local $ENV{ORIGINAL_RECIPIENT} = $addr;

	# ensure successful message delivery
	{
		my $simple = Email::Simple->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

zzzzzz
EOF
		my $in = $simple->as_string;
		run_with_env({PATH => $main_path}, [$mda], \$in);
		local $ENV{GIT_DIR} = $maindir;
		my $rev = `git rev-list HEAD`;
		like($rev, qr/\A[a-f0-9]{40}/, "good revision committed");
	}
	my $app = require $psgi;

	# redirect with trailing /
	test_psgi($app, sub {
		my ($cb) = @_;
		my $from = 'http://example.com/test';
		my $to = "$from/";
		my $res = $cb->(GET($from));
		is(301, $res->code, 'is permanent redirect');
		is($to, $res->header('Location'), 'redirect location matches');
	});

	test_psgi($app, sub {
		my ($cb) = @_;
		my $atomurl = 'http://example.com/test/new.atom';
		my $res = $cb->(GET('http://example.com/test/'));
		is(200, $res->code, 'success response received');
		like($res->content, qr!href="\Q$atomurl\E"!,
			'atom URL generated');
		like($res->content, qr!href="blah%40example\.com/"!,
			'index generated');
	});

	my $pfx = 'http://example.com/test';
	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET($pfx . '/atom.xml'));
		is(200, $res->code, 'success response received for atom');
		like($res->content,
			qr!link\s+href="\Q$pfx\E/blah%40example\.com/"!s,
			'atom feed generated correct URL');
	});

	foreach my $t (('', 'f/')) {
		test_psgi($app, sub {
			my ($cb) = @_;
			my $path = "/blah%40example.com/$t";
			my $res = $cb->(GET($pfx . $path));
			is(200, $res->code, "success for $path");
			like($res->content, qr!<title>hihi - Me</title>!,
				"HTML returned");
		});
	}
	test_psgi($app, sub {
		my ($cb) = @_;
		my $res = $cb->(GET($pfx . '/blah%40example.com/raw'));
		is(200, $res->code, 'success response received for /*/raw');
		like($res->content, qr!\AFrom !, "mbox returned");
	});

	# legacy redirects
	foreach my $t (qw(m f)) {
		test_psgi($app, sub {
			my ($cb) = @_;
			my $res = $cb->(GET($pfx . "/$t/blah%40example.com.txt"));
			is(301, $res->code, "redirect for old $t .txt link");
			my $location = $res->header('Location');
			like($location, qr!/blah%40example\.com/raw\z!,
				".txt redirected to /raw");
		});
	}

	my %umap = (
		'm' => '',
		'f' => 'f/',
		't' => 't/',
	);
	while (my ($t, $e) = each %umap) {
		test_psgi($app, sub {
			my ($cb) = @_;
			my $res = $cb->(GET($pfx . "/$t/blah%40example.com.html"));
			is(301, $res->code, "redirect for old $t .html link");
			my $location = $res->header('Location');
			like($location,
				qr!/blah%40example\.com/$e(?:#u)?\z!,
				".html redirected to new location");
		});
	}
	foreach my $sfx (qw(mbox mbox.gz)) {
		test_psgi($app, sub {
			my ($cb) = @_;
			my $res = $cb->(GET($pfx . "/t/blah%40example.com.$sfx"));
			is(301, $res->code, 'redirect for old thread link');
			my $location = $res->header('Location');
			like($location,
			     qr!/blah%40example\.com/t\.mbox(?:\.gz)?\z!,
			     "$sfx redirected to /mbox.gz");
		});
	}
}

done_testing();

sub run_with_env {
	my ($env, @args) = @_;
	my $init = sub { foreach my $k (keys %$env) { $ENV{$k} = $env->{$k} } };
	run(@args, init => $init);
}
