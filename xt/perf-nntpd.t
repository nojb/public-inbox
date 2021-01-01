# Copyright (C) 2018-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Benchmark qw(:all :hireswallclock);
use PublicInbox::Inbox;
use Net::NNTP;
my $inboxdir = $ENV{GIANT_INBOX_DIR} // $ENV{GIANT_PI_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless defined($inboxdir);
my ($host_port, $group, %opts, $s, $td, $tmp_obj);
use PublicInbox::TestCommon;

if (($ENV{NNTP_TEST_URL} || '') =~ m!\Anntp://([^/]+)/([^/]+)\z!) {
	($host_port, $group) = ($1, $2);
	$host_port .= ":119" unless index($host_port, ':') > 0;
} else {
	$group = 'inbox.test.perf.nntpd';
	my $ibx = { inboxdir => $inboxdir, newsgroup => $group };
	$ibx = PublicInbox::Inbox->new($ibx);
	my $tmpdir;
	($tmpdir, $tmp_obj) = tmpdir();

	my $pi_config = "$tmpdir/config";
	{
		open my $fh, '>', $pi_config or die "open($pi_config): $!";
		print $fh <<"" or die "print $pi_config: $!";
[publicinbox "test"]
	newsgroup = $group
	inboxdir = $inboxdir
	address = test\@example.com

		close $fh or die "close($pi_config): $!";
	}

	my $sock = tcp_server();
	ok($sock, 'sock created');
	my $cmd = [ '-nntpd', '-W0' ];
	$td = start_script($cmd, { PI_CONFIG => $pi_config }, { 3 => $sock });
	$host_port = $sock->sockhost . ':' . $sock->sockport;
}
%opts = (
	PeerAddr => $host_port,
	Proto => 'tcp',
	Timeout => 1,
);
$s = IO::Socket::INET->new(%opts);
$s->autoflush(1);
my $buf = $s->getline;
like($buf, qr/\A201 .* ready - post via email\r\n/s, 'got greeting');

my $t = timeit(10, sub {
	ok($s->print("GROUP $group\r\n"), 'changed group');
	$buf = $s->getline;
});
diag 'GROUP took: ' . timestr($t);

my ($tot, $min, $max) = ($buf =~ /\A211 (\d+) (\d+) (\d+) /);
ok($tot && $min && $max, 'got GROUP response');
my $nr = $max - $min;
my $nmax = 50000;
my $nmin = $max - $nmax;
$nmin = $min if $nmin < $min;
my $res;
my $spec = "$nmin-$max";
my $n;

sub read_until_dot ($) {
	my $n = 0;
	do {
		$buf = $s->getline;
		++$n
	} until $buf eq ".\r\n";
	$n;
}

$t = timeit(1, sub {
	$s->print("XOVER $spec\r\n");
	$n = read_until_dot($s);
});
diag 'xover took: ' . timestr($t) . " for $n";

$t = timeit(1, sub {
	$s->print("HDR From $spec\r\n");
	$n = read_until_dot($s);

});
diag "XHDR From ". timestr($t) . " for $n";

my $date = $ENV{NEWNEWS_DATE};
unless ($date) {
	my (undef, undef, undef, $d, $m, $y) = gmtime(time - 30 * 86400);
	$date = sprintf('%04u%02u%02u', $y + 1900, $m + 1, $d);
	diag "NEWNEWS_DATE undefined, using $date";
}
$t = timeit(1, sub {
	$s->print("NEWNEWS * $date 000000 GMT\r\n");
	$n = read_until_dot($s);
});
diag 'newnews took: ' . timestr($t) . " for $n";

if ($s) {
	$s->print("QUIT\r\n");
	$s->getline;
}


done_testing();

1;
