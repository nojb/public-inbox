#!perl -w
# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use IO::Uncompress::Gunzip qw(gunzip);
use PublicInbox::Eml;
use IO::Handle;
my ($tmpdir, $for_destroy) = tmpdir();
require_mods(qw(Plack::Handler::CGI Plack::Util));
my $slashy_mid = 'slashy/asdf@example.com';
my $ibx = create_inbox 'test', tmpdir => "$tmpdir/test", sub {
	my ($im, $ibx) = @_;
	mkdir "$ibx->{inboxdir}/home", 0755 or BAIL_OUT;
	mkdir "$ibx->{inboxdir}/home/.public-inbox", 0755 or BAIL_OUT;
	my $eml = PublicInbox::Eml->new(<<EOF);
From: Me <me\@example.com>
To: You <you\@example.com>
Cc: $ibx->{-primary_address}
Message-Id: <blah\@example.com>
Subject: hihi
Date: Thu, 01 Jan 1970 00:00:00 +0000

zzzzzz
EOF
	$im->add($eml) or BAIL_OUT;
	$eml->header_set('Message-ID', '<toobig@example.com>');
	$eml->body_set("z\n" x 1024);
	$im->add($eml) or BAIL_OUT;

	$eml = PublicInbox::Eml->new(<<EOF);
From: You <you\@example.com>
To: Me <me\@example.com>
Cc: $ibx->{-primary_address}
In-Reply-To: <blah\@example.com>
Message-Id: <blahblah\@example.com>
Subject: Re: hihi
Date: Thu, 01 Jan 1970 00:00:01 +0000

Me wrote:
> zzzzzz

what?
EOF
	$im->add($eml) or BAIL_OUT;
	$eml = PublicInbox::Eml->new(<<EOF);
From: You <you\@example.com>
To: Me <me\@example.com>
Cc: $ibx->{-primary_address}
Message-Id: <$slashy_mid>
Subject: Re: hihi
Date: Thu, 01 Jan 1970 00:00:01 +0000

slashy
EOF
	$im->add($eml) or BAIL_OUT;
}; # create_inbox

my $home = "$ibx->{inboxdir}/home";
open my $cfgfh, '>>', "$home/.public-inbox/config" or BAIL_OUT $!;
print $cfgfh <<EOF or BAIL_OUT $!;
[publicinbox "test"]
	address = $ibx->{-primary_address}
	inboxdir = $ibx->{inboxdir}
EOF
$cfgfh->flush or BAIL_OUT $!;

{
	local $ENV{HOME} = $home;
	my $res = cgi_run("/test/slashy/asdf\@example.com/raw");
	like($res->{body}, qr/Message-Id: <\Q$slashy_mid\E>/,
		"slashy mid raw hit");
}

# retrieve thread as an mbox
SKIP: {
	local $ENV{HOME} = $home;
	my $path = "/test/blahblah\@example.com/t.mbox.gz";
	my $res = cgi_run($path);
	like($res->{head}, qr/^Status: 501 /, "search not-yet-enabled");
	my $cmd = ['-index', $ibx->{inboxdir}, '--max-size=2k'];
	print $cfgfh "\tindexlevel = basic\n" or BAIL_OUT $!;
	$cfgfh->flush or BAIL_OUT $!;
	my $opt = { 2 => \(my $err) };
	my $indexed = run_script($cmd, undef, $opt);
	if ($indexed) {
		$res = cgi_run($path);
		like($res->{head}, qr/^Status: 200 /, "search returned mbox");
		my $in = $res->{body};
		my $out;
		gunzip(\$in => \$out);
		like($out, qr/^From /m, "From lines in mbox");
		$res = cgi_run('/test/toobig@example.com/');
		like($res->{head}, qr/^Status: 300 /,
			'did not index or return >max-size message');
		like($err, qr/skipping [a-f0-9]{40,}/,
			'warned about skipping large OID');
	} else {
		like($res->{head}, qr/^Status: 501 /, "search not available");
		skip('DBD::SQLite not available', 7); # (4 - 1) above, 4 below
	}
	require_mods('XML::TreePP', 4);
	$path = "/test/blahblah\@example.com/t.atom";
	$res = cgi_run($path);
	like($res->{head}, qr/^Status: 200 /, "atom returned 200");
	like($res->{head}, qr!^Content-Type: application/atom\+xml!m,
		"search returned atom");
	my $t = XML::TreePP->new->parse($res->{body});
	is(scalar @{$t->{feed}->{entry}}, 3, "parsed three entries");
	like($t->{feed}->{-xmlns}, qr/\bAtom\b/,
			'looks like an an Atom feed');
}

done_testing();

sub cgi_run {
	my $env = {
		PATH_INFO => $_[0],
		QUERY_STRING => $_[1] || "",
		SCRIPT_NAME => '',
		REQUEST_URI => $_[0] . ($_[1] ? "?$_[1]" : ''),
		REQUEST_METHOD => $_[2] || "GET",
		GATEWAY_INTERFACE => 'CGI/1.1',
		HTTP_ACCEPT => '*/*',
		HTTP_HOST => 'test.example.com',
	};
	my ($in, $out, $err) = ("", "", "");
	my $rdr = { 0 => \$in, 1 => \$out, 2 => \$err };
	run_script(['.cgi'], $env, $rdr);
	fail "unexpected error: \$?=$? ($err)" if $?;
	my ($head, $body) = split(/\r\n\r\n/, $out, 2);
	{ head => $head, body => $body, err => $err }
}
