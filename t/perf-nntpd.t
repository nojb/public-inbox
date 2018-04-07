# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Benchmark qw(:all :hireswallclock);
use PublicInbox::Inbox;
use File::Temp qw/tempdir/;
use POSIX qw(dup2);
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Net::NNTP;
my $pi_dir = $ENV{GIANT_PI_DIR};
plan skip_all => "GIANT_PI_DIR not defined for $0" unless $pi_dir;
eval { require PublicInbox::Search };
my ($host_port, $group, %opts, $s, $pid);
END {
	if ($s) {
		$s->print("QUIT\r\n");
		$s->getline;
		$s = undef;
	}
	kill 'TERM', $pid if defined $pid;
};

if (($ENV{NNTP_TEST_URL} || '') =~ m!\Anntp://([^/]+)/([^/]+)\z!) {
	($host_port, $group) = ($1, $2);
	$host_port .= ":119" unless index($host_port, ':') > 0;
} else {
	$group = 'inbox.test.perf.nntpd';
	my $ibx = { mainrepo => $pi_dir, newsgroup => $group };
	$ibx = PublicInbox::Inbox->new($ibx);
	my $nntpd = 'blib/script/public-inbox-nntpd';
	my $tmpdir = tempdir('perf-nntpd-XXXXXX', TMPDIR => 1, CLEANUP => 1);

	my $pi_config = "$tmpdir/config";
	{
		open my $fh, '>', $pi_config or die "open($pi_config): $!";
		print $fh <<"" or die "print $pi_config: $!";
[publicinbox "test"]
	newsgroup = $group
	mainrepo = $pi_dir
	address = test\@example.com

		close $fh or die "close($pi_config): $!";
	}

	%opts = (
		LocalAddr => '127.0.0.1',
		ReuseAddr => 1,
		Proto => 'tcp',
		Listen => 1024,
	);
	my $sock = IO::Socket::INET->new(%opts);

	ok($sock, 'sock created');
	$! = 0;
	$pid = fork;
	if ($pid == 0) {
		# pretend to be systemd
		my $fl = fcntl($sock, F_GETFD, 0);
		dup2(fileno($sock), 3) or die "dup2 failed: $!\n";
		dup2(1, 2) or die "dup2 failed: $!\n";
		fcntl($sock, F_SETFD, $fl &= ~FD_CLOEXEC);
		$ENV{LISTEN_PID} = $$;
		$ENV{LISTEN_FDS} = 1;
		$ENV{PI_CONFIG} = $pi_config;
		exec $nntpd, '-W0';
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked nntpd process successfully');
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
is($buf, "201 server ready - post via email\r\n", 'got greeting');

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
	$date = sprintf('%04u%02u%02u', $y + 1900, $m, $d);
	diag "NEWNEWS_DATE undefined, using $date";
}
$t = timeit(1, sub {
	$s->print("NEWNEWS * $date 000000 GMT\r\n");
	$n = read_until_dot($s);
});
diag 'newnews took: ' . timestr($t) . " for $n";

done_testing();

1;
