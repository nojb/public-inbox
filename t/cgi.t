# Copyright (C) 2014-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
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

	# inject some messages:
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

	# deliver a reply, too
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
}

# obvious failures, first
{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/", "", "PUT");
	like($res->{head}, qr/Status:\s*405/i, "PUT not allowed");

	$res = cgi_run("/");
	like($res->{head}, qr/Status:\s*404/i, "index returns 404");
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

	my $res = cgi_run("/test/slashy/asdf\@example.com/raw");
	like($res->{body}, qr/Message-Id: <\Q$slashy_mid\E>/,
		"slashy mid raw hit");

	$res = cgi_run("/test/blahblah\@example.com/raw");
	like($res->{body}, qr/Message-Id: <blahblah\@example\.com>/,
		"mid raw hit");

	$res = cgi_run("/test/blahblah\@example.com/");
	like($res->{body}, qr/\A<html>/, "mid html hit");
	like($res->{head}, qr/Status: 200 OK/, "200 response");

	$res = cgi_run("/test/blahblah\@example.com/f/");
	like($res->{head}, qr/Status: 301 Moved/, "301 response");
	like($res->{head},
		qr!^Location: http://[^/]+/test/blahblah\@example\.com/\r\n!ms,
		'301 redirect location');

	$res = cgi_run("/test/new.html");
	like($res->{body}, qr/slashy%2Fasdf\@example\.com/,
		"slashy URL generated correctly");
}

# retrieve thread as an mbox
{
	local $ENV{HOME} = $home;
	my $path = "/test/blahblah\@example.com/t.mbox.gz";
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
		$path = "/test/blahblah\@example.com/t.atom";
		$res = cgi_run($path);
		like($res->{head}, qr/^Status: 200 /, "atom returned 200");
		like($res->{head}, qr!^Content-Type: application/atom\+xml!m,
			"search returned atom");
		my $p = XML::Feed->parse(\($res->{body}));
		is($p->format, "Atom", "parsed atom feed");
		is(scalar $p->entries, 3, "parsed three entries");
	}
}

done_testing();

sub run_with_env {
	my ($env, @args) = @_;
	IPC::Run::run(@args, init => sub { %ENV = (%ENV, %$env) });
}

sub cgi_run {
	my %env = (
		PATH_INFO => $_[0],
		QUERY_STRING => $_[1] || "",
		SCRIPT_NAME => '',
		REQUEST_URI => $_[0] . ($_[1] ? "?$_[1]" : ''),
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
