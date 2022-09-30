#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use Fcntl qw(SEEK_SET O_RDONLY O_NONBLOCK);
use PublicInbox::Spawn qw(popen_rd);
use List::Util qw(shuffle);
require_mods(qw(DBD::SQLite));
require PublicInbox::MdirReader;
require PublicInbox::MboxReader;
require PublicInbox::LeiOverview;
require PublicInbox::LEI;
use_ok 'PublicInbox::LeiToMail';
my $from = "Content-Length: 10\nSubject: x\n\nFrom hell\n";
my $noeol = "Subject: x\n\nFrom hell";
my $crlf = $noeol;
$crlf =~ s/\n/\r\n/g;
my $kw = [qw(seen answered flagged)];
my $smsg = { kw => $kw, blob => '0'x40 };
my @MBOX = qw(mboxcl2 mboxrd mboxcl mboxo);
for my $mbox (@MBOX) {
	my $m = "eml2$mbox";
	my $cb = PublicInbox::LeiToMail->can($m);
	my $s = $cb->(PublicInbox::Eml->new($from), $smsg);
	is(substr($$s, -1, 1), "\n", "trailing LF in normal $mbox");
	my $eml = PublicInbox::Eml->new($s);
	is($eml->header('Status'), 'RO', "Status: set by $m");
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
	$s = $cb->(PublicInbox::Eml->new($noeol), $smsg);
	is(substr($$s, -1, 1), "\n",
		"trailing LF added by $m when original lacks EOL");
	$eml = PublicInbox::Eml->new($s);
	if ($mbox eq 'mboxcl2') {
		is($eml->body_raw, "From hell\n", "From not escaped by $m");
	} else {
		is($eml->body_raw, ">From hell\n", "From escaped once by $m");
	}
	$s = $cb->(PublicInbox::Eml->new($crlf), $smsg);
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
		$s = $cb->($eml, $smsg);
		$eml = PublicInbox::Eml->new($s);
		is($eml->body_raw,
			">>From hell\r\n\r\n", "From escaped again by $m");
	}
}

my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{TMPDIR} = $tmpdir;
open my $err, '>>', "$tmpdir/lei.err" or BAIL_OUT $!;
my $lei = bless { 2 => $err, cmd => 'test' }, 'PublicInbox::LEI';
my $commit = sub {
	$_[0] = undef; # wcb
	delete $lei->{1};
};
my $buf = <<'EOM';
From: x@example.com
Subject: x

blah
EOM
my $fn = "$tmpdir/x.mbox";
my ($mbox) = shuffle(@MBOX); # pick one, shouldn't matter
my $wcb_get = sub {
	my ($fmt, $dst) = @_;
	delete $lei->{dedupe}; # to be recreated
	$lei->{ovv} = bless {
		fmt => $fmt,
		dst => $dst
	}, 'PublicInbox::LeiOverview';
	my $l2m = PublicInbox::LeiToMail->new($lei);
	SKIP: {
		require_mods('Storable', 1);
		my $dup = Storable::thaw(Storable::freeze($l2m));
		is_deeply($dup, $l2m, "$fmt round-trips through storable");
	}
	$l2m->pre_augment($lei);
	$l2m->do_augment($lei);
	$l2m->post_augment($lei);
	$l2m->write_cb($lei);
};

my $deadbeef = { blob => 'deadbeef', kw => [ qw(seen) ] };
my $orig = do {
	my $wcb = $wcb_get->($mbox, $fn);
	is(ref $wcb, 'CODE', 'write_cb returned callback');
	ok(-f $fn && !-s _, 'empty file created');
	$wcb->(\(my $dup = $buf), $deadbeef);
	$commit->($wcb);
	open my $fh, '<', $fn or BAIL_OUT $!;
	my $raw = do { local $/; <$fh> };
	like($raw, qr/^blah\n/sm, 'wrote content');
	unlink $fn or BAIL_OUT $!;

	$wcb = $wcb_get->($mbox, $fn);
	ok(-f $fn && !-s _, 'truncated mbox destination');
	$wcb->(\($dup = $buf), $deadbeef);
	$commit->($wcb);
	open $fh, '<', $fn or BAIL_OUT $!;
	is(do { local $/; <$fh> }, $raw, 'wrote identical content');
	$raw;
};

test_lei({tmpdir => "$tmpdir/using -F"}, sub {
	lei_ok(qw(import -F), $mbox, $fn, \'imported mbox');
	lei_ok(qw(q s:x), \'lei q works') or diag $lei_err;
	my $res = json_utf8->decode($lei_out);
	my $x = $res->[0];
	is($x->{'s'}, 'x', 'subject imported') or diag $lei_out;
	is_deeply($x->{'kw'}, ['seen'], 'kw imported') or diag $lei_out;
	is($res->[1], undef, 'only one result');
});

test_lei({tmpdir => "$tmpdir/using TYPE: prefix"}, sub {
	lei_ok('import', "$mbox:$fn", \'imported mbox:/path') or diag $lei_err;
	lei_ok(qw(q s:x), \'lei q works') or diag $lei_err;
	my $res = json_utf8->decode($lei_out);
	my $x = $res->[0];
	is($x->{'s'}, 'x', 'subject imported') or diag $lei_out;
	is_deeply($x->{'kw'}, ['seen'], 'kw imported') or diag $lei_out;
	is($res->[1], undef, 'only one result');
});

my $zsfx2cmd = PublicInbox::MboxReader->can('zsfx2cmd');
for my $zsfx (qw(gz bz2 xz)) {
	SKIP: {
		my $cmd = eval { $zsfx2cmd->($zsfx, 0, $lei) };
		skip $@, 3 if $@;
		my $dc_cmd = eval { $zsfx2cmd->($zsfx, 1, $lei) };
		ok($dc_cmd, "decompressor for .$zsfx");
		my $f = "$fn.$zsfx";
		my $wcb = $wcb_get->($mbox, $f);
		$wcb->(\(my $dup = $buf), { %$deadbeef });
		$commit->($wcb);
		my $uncompressed = xqx([@$dc_cmd, $f]);
		is($uncompressed, $orig, "$zsfx works unlocked");

		unlink $f or BAIL_OUT "unlink $!";
		$wcb = $wcb_get->($mbox, $f);
		$wcb->(\($dup = $buf), { %$deadbeef });
		$commit->($wcb);
		is(xqx([@$dc_cmd, $f]), $orig, "$zsfx matches with lock");

		local $lei->{opt} = { augment => 1 };
		$wcb = $wcb_get->($mbox, $f);
		$wcb->(\($dup = $buf . "\nx\n"), { %$deadbeef });
		$commit->($wcb);

		my $cat = popen_rd([@$dc_cmd, $f]);
		my @raw;
		PublicInbox::MboxReader->$mbox($cat,
			sub { push @raw, shift->as_string });
		like($raw[1], qr/\nblah\n\nx\n\z/s, "augmented $zsfx");
		like($raw[0], qr/\nblah\n\z/s, "original preserved $zsfx");

		local $lei->{opt} = { augment => 1 };
		$wcb = $wcb_get->($mbox, $f);
		$wcb->(\($dup = $buf . "\ny\n"), { %$deadbeef });
		$commit->($wcb);

		my @raw3;
		$cat = popen_rd([@$dc_cmd, $f]);
		PublicInbox::MboxReader->$mbox($cat,
			sub { push @raw3, shift->as_string });
		my $y = pop @raw3;
		is_deeply(\@raw3, \@raw, 'previous messages preserved');
		like($y, qr/\nblah\n\ny\n\z/s, "augmented $zsfx (atomic)");
	}
}

my $as_orig = sub {
	my ($eml) = @_;
	$eml->header_set('Status');
	$eml->as_string;
};

unlink $fn or BAIL_OUT $!;
if ('default deduplication uses content_hash') {
	my $wcb = $wcb_get->('mboxo', $fn);
	$deadbeef->{kw} = [];
	$wcb->(\(my $x = $buf), $deadbeef) for (1..2);
	$commit->($wcb);
	my $cmp = '';
	open my $fh, '<', $fn or BAIL_OUT $!;
	PublicInbox::MboxReader->mboxo($fh, sub { $cmp .= $as_orig->(@_) });
	is($cmp, $buf, 'only one message written');

	local $lei->{opt} = { augment => 1 };
	$wcb = $wcb_get->('mboxo', $fn);
	$wcb->(\($x = $buf . "\nx\n"), $deadbeef) for (1..2);
	$commit->($wcb);
	open $fh, '<', $fn or BAIL_OUT $!;
	my @x;
	PublicInbox::MboxReader->mboxo($fh, sub { push @x, $as_orig->(@_) });
	is(scalar(@x), 2, 'augmented mboxo');
	is($x[0], $cmp, 'original message preserved');
	is($x[1], $buf . "\nx\n", 'new message appended');
}

{ # stdout support
	open my $tmp, '+>', undef or BAIL_OUT $!;
	local $lei->{1} = $tmp;
	my $wcb = $wcb_get->('mboxrd', '/dev/stdout');
	$wcb->(\(my $x = $buf), $deadbeef);
	$commit->($wcb);
	seek($tmp, 0, SEEK_SET) or BAIL_OUT $!;
	my $cmp = '';
	PublicInbox::MboxReader->mboxrd($tmp, sub { $cmp .= $as_orig->(@_) });
	is($cmp, $buf, 'message written to stdout');
}

SKIP: { # FIFO support
	use POSIX qw(mkfifo);
	my $fn = "$tmpdir/fifo";
	mkfifo($fn, 0600) or skip("mkfifo not supported: $!", 1);
	sysopen(my $cat, $fn, O_RDONLY|O_NONBLOCK) or BAIL_OUT $!;
	my $wcb = $wcb_get->('mboxo', $fn);
	$wcb->(\(my $x = $buf), $deadbeef);
	$commit->($wcb);
	my $cmp = '';
	$cat->blocking(1);
	PublicInbox::MboxReader->mboxo($cat, sub { $cmp .= $as_orig->(@_) });
	is($cmp, $buf, 'message written to FIFO');
}

{ # Maildir support
	my $mdr = PublicInbox::MdirReader->new;
	my $md = "$tmpdir/maildir/";
	my $wcb = $wcb_get->('maildir', $md);
	is(ref($wcb), 'CODE', 'got Maildir callback');
	my $b4dc0ffee = { blob => 'badc0ffee', kw => [] };
	$wcb->(\(my $x = $buf), $b4dc0ffee);

	my @f;
	$mdr->maildir_each_file($md, sub { push @f, shift });
	open my $fh, '<', $f[0] or BAIL_OUT $!;
	is(do { local $/; <$fh> }, $buf, 'wrote to Maildir');

	$wcb = $wcb_get->('maildir', $md);
	my $deadcafe = { blob => 'deadcafe', kw => [] };
	$wcb->(\($x = $buf."\nx\n"), $deadcafe);

	my @x = ();
	$mdr->maildir_each_file($md, sub { push @x, shift });
	is(scalar(@x), 1, 'wrote one new file');
	ok(!-f $f[0], 'old file clobbered');
	open $fh, '<', $x[0] or BAIL_OUT $!;
	is(do { local $/; <$fh> }, $buf."\nx\n", 'wrote new file to Maildir');

	local $lei->{opt}->{augment} = 1;
	$wcb = $wcb_get->('maildir', $md);
	$wcb->(\($x = $buf."\ny\n"), $deadcafe);
	$wcb->(\($x = $buf."\ny\n"), $b4dc0ffee); # skipped by dedupe
	@f = ();
	$mdr->maildir_each_file($md, sub { push @f, shift });
	is(scalar grep(/\A\Q$x[0]\E\z/, @f), 1, 'old file still there');
	my @new = grep(!/\A\Q$x[0]\E\z/, @f);
	is(scalar @new, 1, '1 new file written (b4dc0ffee skipped)');
	open $fh, '<', $x[0] or BAIL_OUT $!;
	is(do { local $/; <$fh> }, $buf."\nx\n", 'old file untouched');
	open $fh, '<', $new[0] or BAIL_OUT $!;
	is(do { local $/; <$fh> }, $buf."\ny\n", 'new file written');
}

done_testing;
