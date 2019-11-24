# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Integration test to validate compression.
use strict;
use warnings;
use Test::More;
use Symbol qw(gensym);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use POSIX qw(_exit);
my $inbox_dir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inbox_dir;
my $mid = $ENV{TEST_MID};

# Net::NNTP is part of the standard library, but distros may split it off...
foreach my $mod (qw(DBD::SQLite Net::NNTP Compress::Raw::Zlib)) {
	eval "require $mod";
	plan skip_all => "$mod missing for $0" if $@;
}

my $test_compress = Net::NNTP->can('compress');
if (!$test_compress) {
	diag 'Your Net::NNTP does not yet support compression';
	diag 'See: https://rt.cpan.org/Ticket/Display.html?id=129967';
}
my $test_tls = $ENV{TEST_SKIP_TLS} ? 0 : eval { require IO::Socket::SSL };
my $cert = 'certs/server-cert.pem';
my $key = 'certs/server-key.pem';
if ($test_tls && !-r $key || !-r $cert) {
	plan skip_all => "certs/ missing for $0, run $^X ./certs/create-certs.perl";
}
require './t/common.perl';
my ($tmpdir, $ftd) = tmpdir();
$File::Temp::KEEP_ALL = !!$ENV{TEST_KEEP_TMP};
my (%OPT, $td, $host_port, $group);
my $batch = 1000;
if (($ENV{NNTP_TEST_URL} // '') =~ m!\Anntp://([^/]+)/([^/]+)\z!) {
	($host_port, $group) = ($1, $2);
	$host_port .= ":119" unless index($host_port, ':') > 0;
} else {
	make_local_server();
}
my $test_article = $ENV{TEST_ARTICLE} // 0;
my $test_xover = $ENV{TEST_XOVER} // 1;

if ($test_tls) {
	my $nntp = Net::NNTP->new($host_port, %OPT);
	ok($nntp->starttls, 'STARTTLS works');
	ok($nntp->compress, 'COMPRESS works') if $test_compress;
	ok($nntp->quit, 'QUIT after starttls OK');
}
if ($test_compress) {
	my $nntp = Net::NNTP->new($host_port, %OPT);
	ok($nntp->compress, 'COMPRESS works');
	ok($nntp->quit, 'QUIT after compress OK');
}

sub do_get_all {
	my ($methods) = @_;
	my $desc = join(',', @$methods);
	my $t0 = clock_gettime(CLOCK_MONOTONIC);
	my $dig = Digest::SHA->new(1);
	my $digfh = gensym;
	my $tmpfh;
	if ($File::Temp::KEEP_ALL) {
		open $tmpfh, '>', "$tmpdir/$desc.raw" or die $!;
	}
	my $tmp = { dig => $dig, tmpfh => $tmpfh };
	tie *$digfh, 'DigestPipe', $tmp;
	my $nntp = Net::NNTP->new($host_port, %OPT);
	$nntp->article("<$mid>", $digfh) if $mid;
	foreach my $m (@$methods) {
		my $res = $nntp->$m;
		print STDERR "# $m got $res ($desc)\n" if !$res;
	}
	$nntp->article("<$mid>", $digfh) if $mid;
	my ($num, $first, $last) = $nntp->group($group);
	unless (defined $num && defined $first && defined $last) {
		warn "Invalid group\n";
		return undef;
	}
	my $i;
	for ($i = $first; $i < $last; $i += $batch) {
		my $j = $i + $batch - 1;
		$j = $last if $j > $last;
		if ($test_xover) {
			my $xover = $nntp->xover("$i-$j");
			for my $n (sort { $a <=> $b } keys %$xover) {
				my $line = join("\t", @{$xover->{$n}});
				$line =~ tr/\r//d;
				$dig->add("$n\t".$line);
			}
		}
		if ($test_article) {
			for my $n ($i..$j) {
				$nntp->article($n, $digfh) and next;
				next if $nntp->code == 423;
				my $res = $nntp->code.' '.  $nntp->message;

				$res =~ tr/\r\n//d;
				print STDERR "# Article $n ($desc): $res\n";
			}
		}
	}

	# hacky bytes_read thing added to Net::NNTP for testing:
	my $bytes_read = '';
	if ($nntp->can('bytes_read')) {
		$bytes_read .= ' '.$nntp->bytes_read.'b';
	}
	my $q = $nntp->quit;
	print STDERR "# quit failed: ".$nntp->code."\n" if !$q;
	my $elapsed = sprintf('%0.3f', clock_gettime(CLOCK_MONOTONIC) - $t0);
	my $res = $dig->hexdigest;
	print STDERR "# $desc - $res (${elapsed}s)$bytes_read\n";
	$res;
}
my @tests = ([]);
push @tests, [ 'compress' ] if $test_compress;
push @tests, [ 'starttls' ] if $test_tls;
push @tests, [ 'starttls', 'compress' ] if $test_tls && $test_compress;
my (@keys, %thr, %res);
for my $m (@tests) {
	my $key = join(',', @$m);
	push @keys, $key;
	pipe(my ($r, $w)) or die;
	my $pid = fork;
	if ($pid == 0) {
		close $r or die;
		my $res = do_get_all($m);
		print $w $res or die;
		$w->flush;
		_exit(0);
	}
	close $w or die;
	$thr{$key} = [ $pid, $r ];
}
for my $key (@keys) {
	my ($pid, $r) = @{delete $thr{$key}};
	local $/;
	$res{$key} = <$r>;
	defined $res{$key} or die "nothing for $key";
	my $w = waitpid($pid, 0);
	defined($w) or die;
	$w == $pid or die "waitpid($pid) != $w)";
	is($?, 0, "`$key' exited successfully")
}

my $plain = $res{''};
ok($plain, "plain got $plain");
is($res{$_}, $plain, "$_ matches '' result") for @keys;

done_testing();

sub make_local_server {
	require PublicInbox::Inbox;
	$group = 'inbox.test.perf.nntpd';
	my $ibx = { inboxdir => $inbox_dir, newsgroup => $group };
	$ibx = PublicInbox::Inbox->new($ibx);
	my $pi_config = "$tmpdir/config";
	{
		open my $fh, '>', $pi_config or die "open($pi_config): $!";
		print $fh <<"" or die "print $pi_config: $!";
[publicinbox "test"]
	newsgroup = $group
	inboxdir = $inbox_dir
	address = test\@example.com

		close $fh or die "close($pi_config): $!";
	}
	my ($out, $err) = ("$tmpdir/out", "$tmpdir/err");
	for ($out, $err) {
		open my $fh, '>', $_ or die "truncate: $!";
	}
	my $sock = tcp_server();
	ok($sock, 'sock created');
	$host_port = $sock->sockhost . ':' . $sock->sockport;

	# not using multiple workers, here, since we want to increase
	# the chance of tripping concurrency bugs within PublicInbox/NNTP*.pm
	my $cmd = [ '-nntpd', "--stdout=$out", "--stderr=$err", '-W0' ];
	push @$cmd, "-lnntp://$host_port";
	if ($test_tls) {
		push @$cmd, "--cert=$cert", "--key=$key";
		%OPT = (
			SSL_hostname => 'server.local',
			SSL_verifycn_name => 'server.local',
			SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER(),
			SSL_ca_file => 'certs/test-ca.pem',
		);
	}
	print STDERR "# CMD ". join(' ', @$cmd). "\n";
	my $env = { PI_CONFIG => $pi_config };
	$td = start_script($cmd, $env, { 3 => $sock });
}

package DigestPipe;
use strict;
use warnings;

sub TIEHANDLE {
	my ($class, $self) = @_;
	bless $self, $class;
}

sub PRINT {
	my $self = shift;
	my $data = join('', @_);
	# Net::NNTP emit different line-endings depending on TLS or not...:
	$data =~ tr/\r//d;
	$self->{dig}->add($data);
	if (my $tmpfh = $self->{tmpfh}) {
		print $tmpfh $data;
	}
	1;
}
1;
