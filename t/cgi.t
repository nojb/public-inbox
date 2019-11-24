# Copyright (C) 2014-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# FIXME: this test is too slow and most non-CGI-requirements
# should be moved over to things which use test_psgi
use strict;
use warnings;
use Test::More;
use Email::MIME;
require './t/common.perl';
my ($tmpdir, $for_destroy) = tmpdir();
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
		"$cfgpfx.inboxdir" => $maindir,
		"$cfgpfx.indexlevel" => 'basic',
	);
	while (my ($k,$v) = each %cfg) {
		is(0, system(qw(git config --file), $pi_config, $k, $v),
			"setup $k");
	}
}

use_ok 'PublicInbox::Git';
use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Inbox';
use_ok 'PublicInbox::InboxWritable';
use_ok 'PublicInbox::Config';
my $cfg = PublicInbox::Config->new($pi_config);
my $ibx = $cfg->lookup_name('test');
my $im = PublicInbox::InboxWritable->new($ibx)->importer;

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

	my $slashy_mid = 'slashy/asdf@example.com';
	my $slashy = Email::MIME->new(<<EOF);
From: You <you\@example.com>
To: Me <me\@example.com>
Cc: $addr
Message-Id: <$slashy_mid>
Subject: Re: hihi
Date: Thu, 01 Jan 1970 00:00:01 +0000

slashy
EOF
	$im->add($slashy);
	$im->done;

	my $res = cgi_run("/test/slashy/asdf\@example.com/raw");
	like($res->{body}, qr/Message-Id: <\Q$slashy_mid\E>/,
		"slashy mid raw hit");
}

# retrieve thread as an mbox
{
	local $ENV{HOME} = $home;
	my $path = "/test/blahblah\@example.com/t.mbox.gz";
	my $res = cgi_run($path);
	like($res->{head}, qr/^Status: 501 /, "search not-yet-enabled");
	my $indexed;
	eval {
		require DBD::SQLite;
		require PublicInbox::SearchIdx;
		my $s = PublicInbox::SearchIdx->new($ibx, 1);
		$s->index_sync;
		$indexed = 1;
	};
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
		SKIP: { skip 'DBD::SQLite not available', 2 };
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
	} else {
		SKIP: { skip 'DBD::SQLite or XML::Feed missing', 2 };
	}
}

done_testing();

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
	my $rdr = { 0 => \$in, 1 => \$out, 2 => \$err };
	run_script(['.cgi'], \%env, $rdr);
	die "unexpected error: \$?=$?" if $?;
	my ($head, $body) = split(/\r\n\r\n/, $out, 2);
	{ head => $head, body => $body, err => $err }
}
