# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use IO::Socket;
use Fcntl qw(FD_CLOEXEC F_SETFD F_GETFD);
use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
use POSIX qw(dup2 setsid);
use Cwd qw(getcwd);

my $git_dir = $ENV{GIANT_GIT_DIR};
plan 'skip_all' => 'GIANT_GIT_DIR not defined' unless $git_dir;
foreach my $mod (qw(Danga::Socket
			Plack::Util Plack::Builder
			HTTP::Date HTTP::Status Net::HTTP)) {
	eval "require $mod";
	plan skip_all => "$mod missing for git-http-backend.t" if $@;
}
my $psgi = getcwd()."/t/git-http-backend.psgi";
my $tmpdir = tempdir('pi-git-http-backend-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $httpd = 'blib/script/public-inbox-httpd';
my %opts = (
	LocalAddr => '127.0.0.1',
	ReuseAddr => 1,
	Proto => 'tcp',
	Type => SOCK_STREAM,
	Listen => 1024,
);
my $sock = IO::Socket::INET->new(%opts);
my $host = $sock->sockhost;
my $port = $sock->sockport;
my $pid;
END { kill 'TERM', $pid if defined $pid };

my $get_maxrss = sub {
        my $http = Net::HTTP->new(Host => "$host:$port");
	ok($http, 'Net::HTTP object created for maxrss');
        $http->write_request(GET => '/');
        my ($code, $mess, %h) = $http->read_response_headers;
	is($code, 200, 'success reading maxrss');
	my $n = $http->read_entity_body(my $buf, 256);
	ok(defined $n, 'read response body');
	like($buf, qr/\A\d+\n\z/, 'got memory response');
	ok(int($buf) > 0, 'got non-zero memory response');
	int($buf);
};

{
	ok($sock, 'sock created');
	$pid = fork;
	if ($pid == 0) { # pretend to be systemd
		fcntl($sock, F_SETFD, 0);
		dup2(fileno($sock), 3) or die "dup2 failed: $!\n";
		$ENV{LISTEN_PID} = $$;
		$ENV{LISTEN_FDS} = 1;
		$ENV{TEST_CHUNK} = '1';
		exec $httpd, "--stdout=$out", "--stderr=$err", $psgi;
		die "FAIL: $!\n";
	}
	ok(defined $pid, 'forked httpd process successfully');
}
my $mem_a = $get_maxrss->();

SKIP: {
	my $max = 0;
	my $pack;
	my $glob = "$git_dir/objects/pack/pack-*.pack";
	foreach my $f (glob($glob)) {
		my $n = -s $f;
		if ($n > $max) {
			$max = $n;
			$pack = $f;
		}
	}
	skip "no packs found in $git_dir" unless defined $pack;
	if ($pack !~ m!(/objects/pack/pack-[a-f0-9]{40}.pack)\z!) {
		skip "bad pack name: $pack";
	}
	my $url = $1;
	my $http = Net::HTTP->new(Host => "$host:$port");
	ok($http, 'Net::HTTP object created');
	$http->write_request(GET => $url);
	my ($code, $mess, %h) = $http->read_response_headers;
	is(200, $code, 'got 200 success for pack');
	is($max, $h{'Content-Length'}, 'got expected Content-Length for pack');
	foreach my $i (1..3) {
		sleep 1;
		my $diff = $get_maxrss->() - $mem_a;
		note "${diff}K memory increase after $i seconds";
		ok($diff < 1024, 'no bloating caused by slow dumb client');
	}
}

{
	my $c = fork;
	if ($c == 0) {
		setsid();
		exec qw(git clone -q --mirror), "http://$host:$port/",
			"$tmpdir/mirror.git";
		die "Failed start git clone: $!\n";
	}
	select(undef, undef, undef, 0.1);
	foreach my $i (1..10) {
		is(1, kill('STOP', -$c), 'signaled clone STOP');
		sleep 1;
		ok(kill('CONT', -$c), 'continued clone');
		my $diff = $get_maxrss->() - $mem_a;
		note "${diff}K memory increase after $i seconds";
		ok($diff < 2048, 'no bloating caused by slow smart client');
	}
	ok(kill('CONT', -$c), 'continued clone');
	is($c, waitpid($c, 0), 'reaped wayward slow clone');
	is($?, 0, 'clone did not error out');
	note 'clone done, fsck-ing clone result...';
	is(0, system("git", "--git-dir=$tmpdir/mirror.git",
			qw(fsck --no-progress)),
		'fsck did not report corruption');

	my $diff = $get_maxrss->() - $mem_a;
	note "${diff}K memory increase after smart clone";
	ok($diff < 2048, 'no bloating caused by slow smart client');
}

{
	ok(kill('TERM', $pid), 'killed httpd');
	$pid = undef;
	waitpid(-1, 0);
}

done_testing();
