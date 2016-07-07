# Copyright (C) 2014-2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# FIXME: this test is too slow and most non-CGI-requirements
# should be moved over to things which use test_psgi
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
use Cwd;
eval { require IPC::Run };
plan skip_all => "missing IPC::Run for t/cgi.t" if $@;

use constant CGI => "blib/script/public-inbox.cgi";
my $index = "blib/script/public-inbox-index";
my $tmpdir = tempdir('pi-cgi-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $home = "$tmpdir/pi-home";
my $pi_home = "$home/.public-inbox";
my $pi_config = "$pi_home/config";
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";

{
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
}

use_ok 'PublicInbox::Git';
use_ok 'PublicInbox::Import';
use_ok 'Email::MIME';
my $git = PublicInbox::Git->new($maindir);
my $im = PublicInbox::Import->new($git, 'test', $addr);

{
	local $ENV{HOME} = $home;

	# ensure successful message delivery
	{
		my $mime = Email::MIME->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $addr
Message-Id: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

zzzzzz
EOF
		$im->add($mime);
		$im->done;
		my $rev = `git --git-dir=$maindir rev-list HEAD`;
		like($rev, qr/\A[a-f0-9]{40}/, "good revision committed");
	}

	# deliver a reply, too
	{
		my $reply = Email::MIME->new(<<EOF);
From: You <you\@example.com>
To: Me <me\@example.com>
Cc: $addr
In-Reply-To: <blah\@example.com>
Message-Id: <blahblah\@example.com>
Subject: Re: hihi
Date: Thu, 01 Jan 1970 00:00:01 +0000

Me wrote:
> zzzzzz

what?
EOF
		$im->add($reply);
		$im->done;
		my $rev = `git --git-dir=$maindir rev-list HEAD`;
		like($rev, qr/\A[a-f0-9]{40}/, "good revision committed");
	}

}

# obvious failures, first
{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/", "", "PUT");
	like($res->{head}, qr/Status:\s*405/i, "PUT not allowed");

	$res = cgi_run("/");
	like($res->{head}, qr/Status:\s*404/i, "index returns 404");
}

# dumb HTTP support
{
	local $ENV{HOME} = $home;
	my $path = "/test/info/refs";
	my $res = cgi_run($path);
	like($res->{head}, qr/Status:\s*200/i, "info/refs readable");
	my $orig = $res->{body};

	local $ENV{HTTP_RANGE} = 'bytes=5-10';
	$res = cgi_run($path);
	like($res->{head}, qr/Status:\s*206/i, "info/refs partial OK");
	is($res->{body}, substr($orig, 5, 6), 'partial body OK');

	local $ENV{HTTP_RANGE} = 'bytes=5-';
	$res = cgi_run($path);
	like($res->{head}, qr/Status:\s*206/i, "info/refs partial past end OK");
	is($res->{body}, substr($orig, 5), 'partial body OK past end');
}

# atom feeds
{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/test/atom.xml");
	like($res->{body}, qr/<title>test for public-inbox/,
		"set title in XML feed");
	like($res->{body},
		qr!http://test\.example\.com/test/blah%40example\.com/!,
		"link id set");
	like($res->{body}, qr/what\?/, "reply included");
}

# message-id pages
{
	local $ENV{HOME} = $home;
	my $slashy_mid = 'slashy/asdf@example.com';
	my $reply = Email::MIME->new(<<EOF);
From: You <you\@example.com>
To: Me <me\@example.com>
Cc: $addr
Message-Id: <$slashy_mid>
Subject: Re: hihi
Date: Thu, 01 Jan 1970 00:00:01 +0000

slashy
EOF
	$im->add($reply);
	$im->done;

	my $res = cgi_run("/test/slashy%2fasdf%40example.com/raw");
	like($res->{body}, qr/Message-Id: <\Q$slashy_mid\E>/,
		"slashy mid raw hit");

	$res = cgi_run("/test/blahblah\@example.com/raw");
	like($res->{body}, qr/Message-Id: <blahblah\@example\.com>/,
		"mid raw hit");
	$res = cgi_run("/test/blahblah\@example.con/raw");
	like($res->{head}, qr/Status: 300 Multiple Choices/, "mid raw miss");

	$res = cgi_run("/test/blahblah\@example.com/");
	like($res->{body}, qr/\A<html>/, "mid html hit");
	like($res->{head}, qr/Status: 200 OK/, "200 response");
	$res = cgi_run("/test/blahblah\@example.con/");
	like($res->{head}, qr/Status: 300 Multiple Choices/, "mid html miss");

	$res = cgi_run("/test/blahblah\@example.com/f/");
	like($res->{head}, qr/Status: 301 Moved/, "301 response");
	like($res->{head},
		qr!^Location: http://[^/]+/test/blahblah%40example\.com/\r\n!ms,
		'301 redirect location');
	$res = cgi_run("/test/blahblah\@example.con/");
	like($res->{head}, qr/Status: 300 Multiple Choices/, "mid html miss");

	$res = cgi_run("/test/new.html");
	like($res->{body}, qr/slashy%2Fasdf%40example\.com/,
		"slashy URL generated correctly");
}

# retrieve thread as an mbox
{
	local $ENV{HOME} = $home;
	my $path = "/test/blahblah%40example.com/t.mbox.gz";
	my $res = cgi_run($path);
	like($res->{head}, qr/^Status: 501 /, "search not-yet-enabled");
	my $indexed = system($index, $maindir) == 0;
	if ($indexed) {
		$res = cgi_run($path);
		like($res->{head}, qr/^Status: 200 /, "search returned mbox");
		eval {
			require IO::Uncompress::Gunzip;
			my $in = $res->{body};
			my $out;
			IO::Uncompress::Gunzip::gunzip(\$in => \$out);
			like($out, qr/^From /m, "From lines in mbox");
		};
	} else {
		like($res->{head}, qr/^Status: 501 /, "search not available");
	}

	my $have_xml_feed = eval { require XML::Feed; 1 } if $indexed;
	if ($have_xml_feed) {
		$path = "/test/blahblah%40example.com/t.atom";
		$res = cgi_run($path);
		like($res->{head}, qr/^Status: 200 /, "atom returned 200");
		like($res->{head}, qr!^Content-Type: application/atom\+xml!m,
			"search returned atom");
		my $p = XML::Feed->parse(\($res->{body}));
		is($p->format, "Atom", "parsed atom feed");
		is(scalar $p->entries, 3, "parsed three entries");
	}
}

# redirect list-name-only URLs
{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/test");
	like($res->{head}, qr/Status: 301 Moved/, "redirected status");
	like($res->{head}, qr!/test/!, "redirected with slash");
}

done_testing();

sub run_with_env {
	my ($env, @args) = @_;
	my $init = sub { foreach my $k (keys %$env) { $ENV{$k} = $env->{$k} } };
	IPC::Run::run(@args, init => $init);
}

sub cgi_run {
	my %env = (
		PATH_INFO => $_[0],
		QUERY_STRING => $_[1] || "",
		REQUEST_METHOD => $_[2] || "GET",
		GATEWAY_INTERFACE => 'CGI/1.1',
		HTTP_ACCEPT => '*/*',
		HTTP_HOST => 'test.example.com',
	);
	my ($in, $out, $err) = ("", "", "");
	my $rc = run_with_env(\%env, [CGI], \$in, \$out, \$err);
	my ($head, $body) = split(/\r\n\r\n/, $out, 2);
	{ head => $head, body => $body, rc => $rc, err => $err }
}
