#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use POSIX qw(mkfifo);
use Fcntl qw(SEEK_SET O_RDONLY O_NONBLOCK);
use IO::Uncompress::Gunzip qw(gunzip);
use IO::Compress::Gzip qw(gzip);
use PublicInbox::MboxReader;
use PublicInbox::Spawn qw(popen_rd);
test_lei(sub {
lei_ok(qw(import -F eml t/plack-qp.eml));
my $o = "$ENV{HOME}/dst";
lei_ok(qw(q -o), "maildir:$o", qw(m:qp@example.com));
my @fn = glob("$o/cur/*:2,");
scalar(@fn) == 1 or BAIL_OUT "wrote multiple or zero files: ".explain(\@fn);
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

my $exp = {
	'<qp@example.com>' => eml_load('t/plack-qp.eml'),
	'<testmessage@example.com>' => eml_load('t/utf8.eml'),
};
$exp->{'<qp@example.com>'}->header_set('Status', 'OR');
$exp->{'<testmessage@example.com>'}->header_set('Status', 'O');
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
	$buf =~ s/\nStatus: O\n\n/\nStatus: OR\n\n/s or
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
	like($lei_out, qr/^Status: OR\n/sm, 'Status set by previous augment');
}

});
done_testing;
