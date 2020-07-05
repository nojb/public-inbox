#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Expensive test to validate compression and TLS.
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::DS qw(now);
use PublicInbox::Spawn qw(which popen_rd);
use Digest::MD5;
use POSIX qw(_exit);
my $inboxdir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;
my $curl = which('curl') or plan skip_all => "curl(1) missing for $0";
my ($tmpdir, $for_destroy) = tmpdir();
require_mods(qw(DBD::SQLite));
my $JOBS = $ENV{TEST_JOBS} // 4;
my $endpoint = $ENV{TEST_ENDPOINT} // 'all.mbox.gz';
my $curl_opt = $ENV{TEST_CURL_OPT} // '';
diag "TEST_JOBS=$JOBS TEST_ENDPOINT=$endpoint TEST_CURL_OPT=$curl_opt";

# we set Host: to ensure stable results across test runs
my @CURL_OPT = (qw(-HHost:example.com -sSf), split(' ', $curl_opt));

my $make_local_server = sub {
	my $pi_config = "$tmpdir/config";
	open my $fh, '>', $pi_config or die "open($pi_config): $!";
	print $fh <<"" or die "print $pi_config: $!";
[publicinbox "test"]
inboxdir = $inboxdir
address = test\@example.com

	close $fh or die "close($pi_config): $!";
	my ($out, $err) = ("$tmpdir/out", "$tmpdir/err");
	for ($out, $err) {
		open my $fh, '>', $_ or die "truncate: $!";
	}
	my $http = tcp_server();
	my $rdr = { 3 => $http };

	# not using multiple workers, here, since we want to increase
	# the chance of tripping concurrency bugs within PublicInbox/HTTP*.pm
	my $cmd = [ '-httpd', "--stdout=$out", "--stderr=$err", '-W0' ];
	my $host_port = $http->sockhost.':'.$http->sockport;
	push @$cmd, "-lhttp://$host_port";
	my $url = "$host_port/test/$endpoint";
	print STDERR "# CMD ". join(' ', @$cmd). "\n";
	my $env = { PI_CONFIG => $pi_config };
	(start_script($cmd, $env, $rdr), $url);
};

my ($td, $url) = $make_local_server->();

my $do_get_all = sub {
	my ($job) = @_;
	local $SIG{__DIE__} = sub { print STDERR $job, ': ', @_; _exit(1) };
	my $dig = Digest::MD5->new;
	my ($buf, $nr);
	my $bytes = 0;
	my $t0 = now();
	my ($rd, $pid) = popen_rd([$curl, @CURL_OPT, $url]);
	while (1) {
		$nr = sysread($rd, $buf, 65536);
		last if !$nr;
		$dig->add($buf);
		$bytes += $nr;
	}
	my $res = $dig->hexdigest;
	my $elapsed = sprintf('%0.3f', now() - $t0);
	close $rd or die "close curl failed: $!\n";
	waitpid($pid, 0) == $pid or die "waitpid failed: $!\n";
	$? == 0 or die "curl failed: $?\n";
	print STDERR "# $job $$ ($?) $res (${elapsed}s) $bytes bytes\n";
	$res;
};

my (%pids, %res);
for my $job (1..$JOBS) {
	pipe(my ($r, $w)) or die;
	my $pid = fork;
	if ($pid == 0) {
		close $r or die;
		my $res = $do_get_all->($job);
		print $w $res or die;
		close $w or die;
		_exit(0);
	}
	close $w or die;
	$pids{$pid} = [ $job, $r ];
}

while (scalar keys %pids) {
	my $pid = waitpid(-1, 0) or next;
	my $child = delete $pids{$pid} or next;
	my ($job, $rpipe) = @$child;
	is($?, 0, "$job done");
	my $sum = do { local $/; <$rpipe> };
	push @{$res{$sum}}, $job;
}
is(scalar keys %res, 1, 'all got the same result');
$td->kill;
$td->join;
is($?, 0, 'no error on -httpd exit');
done_testing;
