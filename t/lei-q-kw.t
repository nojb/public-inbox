#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use POSIX qw(mkfifo);
use Fcntl qw(SEEK_SET O_RDONLY O_NONBLOCK);
use IO::Uncompress::Gunzip qw(gunzip);
use IO::Compress::Gzip qw(gzip);
use PublicInbox::MboxReader;
use PublicInbox::LeiToMail;
use PublicInbox::Spawn qw(popen_rd);
my $exp = {
	'<qp@example.com>' => eml_load('t/plack-qp.eml'),
	'<testmessage@example.com>' => eml_load('t/utf8.eml'),
};
$exp->{'<qp@example.com>'}->header_set('Status', 'RO');
$exp->{'<testmessage@example.com>'}->header_set('Status', 'O');

test_lei(sub {
lei_ok(qw(import -F eml t/plack-qp.eml));
my $o = "$ENV{HOME}/dst";
lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
my @fn = glob("$o/cur/*:2,");
scalar(@fn) == 1 or xbail $lei_err, 'wrote multiple or zero files:', \@fn;
rename($fn[0], "$fn[0]S") or BAIL_OUT "rename $!";

lei_ok(qw(q -o), "maildir:$o", qw(m:bogus-noresults@example.com));
ok(!glob("$o/cur/*"), 'last result cleared after augment-import');

lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
@fn = glob("$o/cur/*:2,S");
is(scalar(@fn), 1, "`seen' flag set on Maildir file");

# ensure --no-import-before works
my $n = $fn[0];
$n =~ s/,S\z/,RS/;
rename($fn[0], $n) or BAIL_OUT "rename $!";
lei_ok(qw(q --no-import-before -o), "maildir:$o",
	qw(m:bogus-noresults@example.com));
ok(!glob("$o/cur/*"), '--no-import-before cleared destination');
lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
@fn = glob("$o/cur/*:2,S");
is(scalar(@fn), 1, "`seen' flag (but not `replied') set on Maildir file");

SKIP: {
	$o = "$ENV{HOME}/fifo";
	mkfifo($o, 0600) or skip("mkfifo not supported: $!", 1);
	# cat(1) since lei() may not execve for FD_CLOEXEC to work
	my $cat = popen_rd(['cat', $o]);
	ok(!lei(qw(q --import-before bogus -o), "mboxrd:$o"),
		'--import-before fails on non-seekable output');
	is(do { local $/; <$cat> }, '', 'no output on FIFO');
	close $cat;
	$cat = popen_rd(['cat', $o]);
	lei_ok(qw(q m:qp@example.com -o), "mboxrd:$o");
	my $buf = do { local $/; <$cat> };
	open my $fh, '<', \$buf or BAIL_OUT $!;
	PublicInbox::MboxReader->mboxrd($fh, sub {
		my ($eml) = @_;
		$eml->header_set('Status', 'RO');
		is_deeply($eml, $exp->{'<qp@example.com>'},
			'FIFO output works as expected');
	});
};

lei_ok qw(import -F eml t/utf8.eml), \'for augment test';
my $read_file = sub {
	if ($_[0] =~ /\.gz\z/) {
		gunzip($_[0] => \(my $buf = ''), MultiStream => 1) or
			BAIL_OUT 'gunzip';
		$buf;
	} else {
		open my $fh, '+<', $_[0] or BAIL_OUT $!;
		do { local $/; <$fh> };
	}
};

my $write_file = sub {
	if ($_[0] =~ /\.gz\z/) {
		gzip(\($_[1]), $_[0]) or BAIL_OUT 'gzip';
	} else {
		open my $fh, '>', $_[0] or BAIL_OUT $!;
		print $fh $_[1] or BAIL_OUT $!;
		close $fh or BAIL_OUT;
	}
};

for my $sfx ('', '.gz') {
	$o = "$ENV{HOME}/dst.mboxrd$sfx";
	lei_ok(qw(q -o), "mboxrd:$o", qw(m:qp@example.com));
	my $buf = $read_file->($o);
	$buf =~ s/^Status: [^\n]*\n//sm or BAIL_OUT "no status in $buf";
	$write_file->($o, $buf);
	lei_ok(qw(q -o), "mboxrd:$o", qw(rereadandimportkwchange));
	$buf = $read_file->($o);
	is($buf, '', 'emptied');
	lei_ok(qw(q -o), "mboxrd:$o", qw(m:qp@example.com));
	$buf = $read_file->($o);
	$buf =~ s/\nStatus: O\n\n/\nStatus: RO\n\n/s or
		BAIL_OUT "no Status in $buf";
	$write_file->($o, $buf);
	lei_ok(qw(q -a -o), "mboxrd:$o", qw(m:testmessage@example.com));
	$buf = $read_file->($o);
	open my $fh, '<', \$buf or BAIL_OUT "PerlIO::scalar $!";
	my %res;
	PublicInbox::MboxReader->mboxrd($fh, sub {
		my ($eml) = @_;
		$res{$eml->header_raw('Message-ID')} = $eml;
	});
	is_deeply(\%res, $exp, '--augment worked');

	lei_ok(qw(q -o), "mboxrd:/dev/stdout", qw(m:qp@example.com)) or
		diag $lei_err;
	like($lei_out, qr/^Status: RO\n/sm, 'Status set by previous augment');
} # /mbox + mbox.gz tests

my ($ro_home, $cfg_path) = setup_public_inboxes;

# import keywords-only for external messages:
$o = "$ENV{HOME}/kwdir";
my $m = 'alpine.DEB.2.20.1608131214070.4924@example';
my @inc = ('-I', "$ro_home/t1");
lei_ok(qw(q -o), $o, "m:$m", @inc);

# emulate MUA marking a Maildir message as read:
@fn = glob("$o/cur/*");
scalar(@fn) == 1 or xbail $lei_err, 'wrote multiple or zero files:', \@fn;
rename($fn[0], "$fn[0]S") or BAIL_OUT "rename $!";

lei_ok(qw(q -o), $o, 'bogus', \'clobber output dir to import keywords');
@fn = glob("$o/cur/*");
is_deeply(\@fn, [], 'output dir actually clobbered');
lei_ok('q', "m:$m", @inc);
my $res = json_utf8->decode($lei_out);
is_deeply($res->[0]->{kw}, ['seen'], 'seen flag set for external message')
	or diag explain($res);
lei_ok('q', "m:$m", '--no-external');
is_deeply($res = json_utf8->decode($lei_out), [ undef ],
	'external message not imported') or diag explain($res);

$o = "$ENV{HOME}/kwmboxrd";
lei_ok(qw(q -o), "mboxrd:$o", "m:$m", @inc);

# emulate MUA marking mboxrd message as unread
open my $fh, '<', $o or BAIL_OUT;
my $s = do { local $/; <$fh> };
$s =~ s/^Status: RO\n/Status: O\nX-Status: AF\n/sm or
	fail "failed to clear R flag in $s";
open $fh, '>', $o or BAIL_OUT;
print $fh $s or BAIL_OUT;
close $fh or BAIL_OUT;

lei_ok(qw(q -o), "mboxrd:$o", 'm:bogus', @inc,
	\'clobber mbox to import keywords');
lei_ok(qw(q -o), "mboxrd:$o", "m:$m", @inc);
open $fh, '<', $o or BAIL_OUT;
$s = do { local $/; <$fh> };
like($s, qr/^Status: O\nX-Status: AF\n/ms,
	'seen keyword gone in mbox, answered + flagged set');

lei_ok(qw(q --pretty), "m:$m", @inc);
like($lei_out, qr/^  "kw": \["answered", "flagged"\],\n/sm,
	'--pretty JSON output shows kw: on one line');

# ensure import on previously external-only message works
lei_ok('q', "m:$m");
is_deeply(json_utf8->decode($lei_out), [ undef ],
	'to-be-imported message non-existent');
lei_ok(qw(import -F eml t/x-unknown-alpine.eml));
is($lei_err, '', 'no errors importing previous external-only message');
lei_ok('q', "m:$m");
$res = json_utf8->decode($lei_out);
is($res->[1], undef, 'got one result');
is_deeply($res->[0]->{kw}, [ qw(answered flagged) ], 'kw preserved on exact');

# ensure fuzzy match import works, too
$m = 'multipart@example.com';
$o = "$ENV{HOME}/fuzz";
lei_ok('q', '-o', $o, "m:$m", @inc);
@fn = glob("$o/cur/*");
scalar(@fn) == 1 or xbail $lei_err, "wrote multiple or zero files", \@fn;
rename($fn[0], "$fn[0]S") or BAIL_OUT "rename $!";
lei_ok('q', '-o', $o, "m:$m");
is_deeply([glob("$o/cur/*")], [], 'clobbered output results');
my $eml = eml_load('t/plack-2-txt-bodies.eml');
$eml->header_set('List-Id', '<list.example.com>');
my $in = $eml->as_string;
lei_ok([qw(import -F eml --stdin)], undef, { 0 => \$in, %$lei_opt });
is($lei_err, '', 'no errors from import');
lei_ok(qw(q -f mboxrd), "m:$m");
open $fh, '<', \$lei_out or BAIL_OUT $!;
my @res;
PublicInbox::MboxReader->mboxrd($fh, sub { push @res, shift });
is($res[0]->header('Status'), 'RO', 'seen kw set');
$res[0]->header_set('Status');
is_deeply(\@res, [ $eml ], 'imported message matches w/ List-Id');

$eml->header_set('List-Id', '<another.example.com>');
$in = $eml->as_string;
lei_ok([qw(import -F eml --stdin)], undef, { 0 => \$in, %$lei_opt });
is($lei_err, '', 'no errors from 2nd import');
lei_ok(qw(q -f mboxrd), "m:$m", 'l:another.example.com');
my @another;
open $fh, '<', \$lei_out or BAIL_OUT $!;
PublicInbox::MboxReader->mboxrd($fh, sub { push @another, shift });
is($another[0]->header('Status'), 'RO', 'seen kw set');

# forwarded
{
	local $ENV{DBG} = 1;
	$o = "$ENV{HOME}/forwarded";
	lei_ok(qw(q -o), $o, "m:$m");
	my @p = glob("$o/cur/*");
	scalar(@p) == 1 or xbail('multiple when 1 expected', \@p);
	my $passed = $p[0];
	$passed =~ s/,S\z/,PS/ or xbail "failed to replace $passed";
	rename($p[0], $passed) or xbail "rename $!";
	lei_ok(qw(q -o), $o, 'm:bogus', \'clobber maildir');
	is_deeply([glob("$o/cur/*")], [], 'old results clobbered');
	lei_ok(qw(q -o), $o, "m:$m");
	@p = glob("$o/cur/*");
	scalar(@p) == 1 or xbail('multiple when 1 expected', \@p);
	like($p[0], qr/,PS/, 'passed (Forwarded) flag kept');
	lei_ok(qw(q -o), "mboxrd:$o.mboxrd", "m:$m");
	open $fh, '<', "$o.mboxrd" or xbail $!;
	my @res;
	PublicInbox::MboxReader->mboxrd($fh, sub { push @res, shift });
	scalar(@res) == 1 or xbail('multiple when 1 expected', \@res);
	is($res[0]->header('Status'), 'RO', 'seen kw set');
	is($res[0]->header('X-Status'), undef, 'no X-Status');

	lei_ok(qw(q -o), "mboxrd:$o.mboxrd", 'bogus-for-import-before');
	lei_ok(qw(q -o), $o, "m:$m");
	@p = glob("$o/cur/*");
	scalar(@p) == 1 or xbail('multiple when 1 expected', \@p);
	like($p[0], qr/,PS/, 'passed (Forwarded) flag still kept');
}

}); # test_lei
done_testing;
