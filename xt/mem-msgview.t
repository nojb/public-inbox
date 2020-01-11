#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Note: this may be altered as-needed to demonstrate improvements.
# See history in git for this file.
use strict;
use IO::Handle; # ->flush
use Fcntl qw(SEEK_SET);
use PublicInbox::TestCommon;
use PublicInbox::Tmpfile;
use Test::More;
my @mods = qw(DBD::SQLite BSD::Resource PublicInbox::WWW);
require_mods(@mods);
use_ok($_) for @mods;
my $lines = $ENV{NR_LINES} // 50000;
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxname = 'big';
my $inboxdir = "$tmpdir/big";
local $ENV{PI_CONFIG} = "$tmpdir/cfg";
my $mid = 'test@example.com';

{ # setup
	open my $fh, '>', "$tmpdir/cfg" or die;
	print $fh <<EOF or die;
[publicinboxmda]
	spamcheck = none
EOF
	close $fh or die;

	my $addr = 'n@example.com';
	ok(run_script([qw(-init -V2 --indexlevel=basic), $inboxname, $inboxdir,
			"http://example.com/$inboxname", $addr]),
		'inbox initialized');

	$fh = tmpfile('big.eml', undef, my $append = 1) or die;
	my $hdr = sprintf(<<'EOF', $addr, $mid);
From: Dr. X <x@example.com>
To: Nikki <%s>
Date: Tue, 3 May 1988 00:00:00 +0000
Subject: todo
Message-ID: <%s>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="FOO"
Content-Disposition: inline

--FOO
Content-Type: text/plain; charset=utf-8
Content-Disposition: inline

EOF
	print $fh $hdr or die;
	for (0..$lines) { print $fh 'x' x 72, "\n" or die }
	print $fh <<EOF or die;

--FOO
Content-Type: text/plain; charset=utf-8
Content-Disposition: inline

EOF
	for (0..$lines) { print $fh 'x' x 72, "\n" or die }
	print $fh "\n--FOO--\n" or die;
	$fh->flush or die;
	sysseek($fh, 0, SEEK_SET) or die;
	my $env = { ORIGINAL_RECIPIENT => $addr };
	my $err = '';
	my $opt = { 0 => $fh, 2 => \$err, run_mode => 0 };
	ok(run_script([qw(-mda --no-precheck)], $env, $opt),
		'message delivered');
}

my $www = PublicInbox::WWW->new;
my $env = {
	PATH_INFO => "/$inboxname/$mid/",
	REQUEST_URI => "/$inboxname/$mid/",
	SCRIPT_NAME => '',
	QUERY_STRING => '',
	REQUEST_METHOD => 'GET',
	HTTP_HOST => 'example.com',
	'psgi.errors' => \*STDERR,
	'psgi.url_scheme' => 'http',
};
my $ru_before = BSD::Resource::getrusage();
my $res = $www->call($env);
my $body = $res->[2];
while (defined(my $x = $body->getline)) {
}
$body->close;
my $ru_after = BSD::Resource::getrusage();
my $diff = $ru_after->maxrss - $ru_before->maxrss;
diag "before: ${\$ru_before->maxrss} => ${\$ru_after->maxrss} diff=$diff kB";
done_testing();
