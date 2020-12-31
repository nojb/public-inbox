#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use_ok 'PublicInbox::LeiToMail';
my $from = "Content-Length: 10\nSubject: x\n\nFrom hell\n";
my $noeol = "Subject: x\n\nFrom hell";
my $crlf = $noeol;
$crlf =~ s/\n/\r\n/g;
my $kw = [qw(seen answered flagged)];
for my $mbox (qw(mboxrd mboxo mboxcl mboxcl2)) {
	my $m = "eml2$mbox";
	my $cb = PublicInbox::LeiToMail->can($m);
	my $s = $cb->(PublicInbox::Eml->new($from), $kw);
	is(substr($$s, -1, 1), "\n", "trailing LF in normal $mbox");
	my $eml = PublicInbox::Eml->new($s);
	is($eml->header('Status'), 'R', "Status: set by $m");
	is($eml->header('X-Status'), 'AF', "X-Status: set by $m");
	if ($mbox eq 'mboxcl2') {
		like($eml->body_raw, qr/^From /, "From not escaped $m");
	} else {
		like($eml->body_raw, qr/^>From /, "From escaped once by $m");
	}
	my @cl = $eml->header('Content-Length');
	if ($mbox =~ /mboxcl/) {
		is(scalar(@cl), 1, "$m only has one Content-Length header");
		is($cl[0] + length("\n"),
			length($eml->body_raw), "$m Content-Length matches");
	} else {
		is(scalar(@cl), 0, "$m clobbered Content-Length");
	}
	$s = $cb->(PublicInbox::Eml->new($noeol), $kw);
	is(substr($$s, -1, 1), "\n",
		"trailing LF added by $m when original lacks EOL");
	$eml = PublicInbox::Eml->new($s);
	if ($mbox eq 'mboxcl2') {
		is($eml->body_raw, "From hell\n", "From not escaped by $m");
	} else {
		is($eml->body_raw, ">From hell\n", "From escaped once by $m");
	}
	$s = $cb->(PublicInbox::Eml->new($crlf), $kw);
	is(substr($$s, -2, 2), "\r\n",
		"trailing CRLF added $m by original lacks EOL");
	$eml = PublicInbox::Eml->new($s);
	if ($mbox eq 'mboxcl2') {
		is($eml->body_raw, "From hell\r\n", "From not escaped by $m");
	} else {
		is($eml->body_raw, ">From hell\r\n", "From escaped once by $m");
	}
	if ($mbox =~ /mboxcl/) {
		is($eml->header('Content-Length') + length("\r\n"),
			length($eml->body_raw), "$m Content-Length matches");
	} elsif ($mbox eq 'mboxrd') {
		$s = $cb->($eml, $kw);
		$eml = PublicInbox::Eml->new($s);
		is($eml->body_raw,
			">>From hell\r\n\r\n", "From escaped again by $m");
	}
}

my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{TMPDIR} = $tmpdir;
open my $err, '>>', "$tmpdir/lei.err" or BAIL_OUT $!;
my $lei = { 2 => $err };
my $buf = <<'EOM';
From: x@example.com
Subject: x

blah
EOM
my $fn = "$tmpdir/x.mbox";
my $orig = do {
	my $wcb = PublicInbox::LeiToMail->write_cb("mboxcl2:$fn", $lei);
	is(ref $wcb, 'CODE', 'write_cb returned callback');
	ok(-f $fn && !-s _, 'empty file created');
	$wcb->(\(my $dup = $buf), 'deadbeef', [ qw(seen) ]);
	undef $wcb;
	open my $fh, '<', $fn or BAIL_OUT $!;
	my $raw = do { local $/; <$fh> };
	like($raw, qr/^blah\n/sm, 'wrote content');
	unlink $fn or BAIL_OUT $!;

	local $lei->{opt} = { jobs => 2 };
	$wcb = PublicInbox::LeiToMail->write_cb("mboxcl2:$fn", $lei);
	$wcb->(\($dup = $buf), 'deadbeef', [ qw(seen) ]);
	undef $wcb;
	open $fh, '<', $fn or BAIL_OUT $!;
	is($raw, do { local $/; <$fh> }, 'jobs > 1');
	$raw;
};
SKIP: {
	use PublicInbox::Spawn qw(which);
	my $gzip = which('gzip') or skip 'gzip not found', 1;
	my $wcb = PublicInbox::LeiToMail->write_cb("mboxcl2:$fn.gz", $lei);
	$wcb->(\(my $dup = $buf), 'deadbeef', [ qw(seen) ]);
	undef $wcb;
	my $uncompressed = xqx([$gzip, '-dc', "$fn.gz"]);
	is($uncompressed, $orig, 'gzip works');

	local $lei->{opt} = { jobs => 2 };
	unlink "$fn.gz" or die "unlink $!";
	$wcb = PublicInbox::LeiToMail->write_cb("mboxcl2:$fn.gz", $lei);
	$wcb->(\(my $dupe = $buf), 'deadbeef', [ qw(seen) ]);
	undef $wcb;
	is(xqx([$gzip, '-dc', "$fn.gz"]), $orig);
}

done_testing;
