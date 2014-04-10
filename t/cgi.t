# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
use Cwd;
use IPC::Run qw/run/;

use constant CGI => "blib/script/public-inbox-cgi";
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

{
	ok(-x "$main_bin/spamc",
		"spamc ham mock found (run in top of source tree");
	ok(-x $mda, "$mda is executable");
	is(1, mkdir($home, 0755), "setup ~/ for testing");
	is(1, mkdir($pi_home, 0755), "setup ~/.public-inbox");
	is(0, system(qw(git init -q --bare), $maindir), "git init (main)");

	my %cfg = (
		"$cfgpfx.address" => $addr,
		"$cfgpfx.mainrepo" => $maindir,
		"$cfgpfx.description" => 'test for public-inbox',
	);
	while (my ($k,$v) = each %cfg) {
		is(0, system(qw(git config --file), $pi_config, $k, $v),
			"setup $k");
	}
}

{
	my $failbox = "$home/fail.mbox";
	local $ENV{PI_FAILBOX} = $failbox;
	local $ENV{HOME} = $home;
	local $ENV{RECIPIENT} = $addr;

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

	# deliver a reply, too
	{
		my $reply = Email::Simple->new(<<EOF);
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
		my $in = $reply->as_string;
		run_with_env({PATH => $main_path}, [$mda], \$in);
		local $ENV{GIT_DIR} = $maindir;
		my $rev = `git rev-list HEAD`;
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

# atom feeds
{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/test/all.atom.xml");
	like($res->{body}, qr/<title>test for public-inbox/,
		"set title in XML feed");
	like($res->{body},
		qr!http://test\.example\.com/test/mid/blah%40example\.com!,
		"link id set");
	like($res->{body}, qr/what\?/, "reply included");

	$res = cgi_run("/test/index.atom.xml");
	unlike($res->{body}, qr/what\?/, "reply not included in index");
}

# indices
{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/test/");
	like($res->{head}, qr/Status: 200 OK/, "index returns 200");
	# more checks in t/feed.t
}


{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/test/m/blahblah\@example.com.txt");
	like($res->{body}, qr/Message-Id: <blahblah\@example\.com>/,
		"mid.txt hit");
	$res = cgi_run("/test/m/blahblah\@example.con.txt");
	like($res->{head}, qr/Status: 404 Not Found/, "mid.txt miss");
}

done_testing();

sub run_with_env {
	my ($env, @args) = @_;
	my $init = sub { foreach my $k (keys %$env) { $ENV{$k} = $env->{$k} } };
	run(@args, init => $init);
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
