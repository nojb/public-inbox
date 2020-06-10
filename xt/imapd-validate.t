#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Expensive test to validate compression and TLS.
use strict;
use Test::More;
use Symbol qw(gensym);
use PublicInbox::DS qw(now);
use POSIX qw(_exit);
use PublicInbox::TestCommon;
my $inbox_dir = $ENV{GIANT_INBOX_DIR};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inbox_dir;
# how many emails to read into memory at once per-process
my $BATCH = $ENV{TEST_BATCH} // 100;
my $REPEAT = $ENV{TEST_REPEAT} // 1;
diag "TEST_BATCH=$BATCH TEST_REPEAT=$REPEAT";

require_mods(qw(Mail::IMAPClient));
my $imap_client = 'Mail::IMAPClient';
my $can_compress = $imap_client->can('compress');
if ($can_compress) { # hope this gets fixed upstream, soon
	require PublicInbox::IMAPClient;
	$imap_client = 'PublicInbox::IMAPClient';
}

my $test_tls = $ENV{TEST_SKIP_TLS} ? 0 : eval { require IO::Socket::SSL };
my ($cert, $key) = qw(certs/server-cert.pem certs/server-key.pem);
if ($test_tls && !-r $key || !-r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run $^X ./certs/create-certs.perl";
}
my ($tmpdir, $for_destroy) = tmpdir();
my %OPT = qw(User u Password p);
my (%STARTTLS_OPT, %IMAPS_OPT, $td, $newsgroup, $mailbox, $make_local_server);
if (($ENV{IMAP_TEST_URL} // '') =~ m!\Aimap://([^/]+)/(.+)\z!) {
	($OPT{Server}, $mailbox) = ($1, $2);
	$OPT{Server} =~ s/:([0-9]+)\z// and $OPT{Port} = $1 + 0;
	%STARTTLS_OPT = %OPT;
	%IMAPS_OPT = (%OPT, Port => 993) if $OPT{Port} == 143;
} else {
	require_mods(qw(DBD::SQLite));
	$make_local_server->();
	$mailbox = "$newsgroup.0";
}

my %opts = (imap => \%OPT, 'imap+compress' => { %OPT, Compress => 1 });
my $uid_max = do {
	my $mic = $imap_client->new(%OPT) or BAIL_OUT "new $!";
	$mic->examine($mailbox) or BAIL_OUT "examine: $!";
	my $next = $mic->uidnext($mailbox) or BAIL_OUT "uidnext: $!";
	$next - 1;
};

if (scalar keys %STARTTLS_OPT) {
	$opts{starttls} = \%STARTTLS_OPT;
	$opts{'starttls+compress'} = { %STARTTLS_OPT, Compress => 1 };
}
if (scalar keys %IMAPS_OPT) {
	$opts{imaps} = \%IMAPS_OPT;
	$opts{'imaps+compress'} = { %IMAPS_OPT, Compress => 1 };
}

my $do_get_all = sub {
	my ($desc, $opt) = @_;
	local $SIG{__DIE__} = sub { print STDERR $desc, ': ', @_; _exit(1) };
	my $t0 = now();
	my $dig = Digest::SHA->new(1);
	my $mic = $imap_client->new(%$opt);
	$mic->examine($mailbox) or die "examine: $!";
	my $uid_base = 1;
	my $bytes = 0;
	my $nr = 0;
	until ($uid_base > $uid_max) {
		my $end = $uid_base + $BATCH;
		my $ret = $mic->fetch_hash("$uid_base:$end", 'BODY[]') or last;
		for my $uid ($uid_base..$end) {
			$dig->add($uid);
			my $h = delete $ret->{$uid} or next;
			my $body = delete $h->{'BODY[]'} or
						die "no BODY[] for UID=$uid";
			$dig->add($body);
			$bytes += length($body);
			++$nr;
		}
		$uid_base = $end + 1;
	}
	$mic->logout or die "logout failed: $!";
	my $elapsed = sprintf('%0.3f', now() - $t0);
	my $res = $dig->hexdigest;
	print STDERR "# $desc $res (${elapsed}s) $bytes bytes, NR=$nr\n";
	$res;
};

my (%pids, %res);
for (1..$REPEAT) {
	while (my ($desc, $opt) = each %opts) {
		pipe(my ($r, $w)) or die;
		my $pid = fork;
		if ($pid == 0) {
			close $r or die;
			my $res = $do_get_all->($desc, $opt);
			print $w $res or die;
			close $w or die;
			_exit(0);
		}
		close $w or die;
		$pids{$pid} = [ $desc, $r ];
	}
}

while (scalar keys %pids) {
	my $pid = waitpid(-1, 0) or next;
	my $child = delete $pids{$pid} or next;
	my ($desc, $rpipe) = @$child;
	is($?, 0, "$desc done");
	my $sum = do { local $/; <$rpipe> };
	push @{$res{$sum}}, $desc;
}
is(scalar keys %res, 1, 'all got the same result');
$td->kill;
$td->join;
is($?, 0, 'no error on -imapd exit');
done_testing;

BEGIN {

$make_local_server = sub {
	require PublicInbox::Inbox;
	$newsgroup = 'inbox.test';
	my $ibx = { inboxdir => $inbox_dir, newsgroup => $newsgroup };
	$ibx = PublicInbox::Inbox->new($ibx);
	my $pi_config = "$tmpdir/config";
	{
		open my $fh, '>', $pi_config or die "open($pi_config): $!";
		print $fh <<"" or die "print $pi_config: $!";
[publicinbox "test"]
	newsgroup = $newsgroup
	inboxdir = $inbox_dir
	address = test\@example.com

		close $fh or die "close($pi_config): $!";
	}
	my ($out, $err) = ("$tmpdir/out", "$tmpdir/err");
	for ($out, $err) {
		open my $fh, '>', $_ or die "truncate: $!";
	}
	my $imap = tcp_server();
	my $rdr = { 3 => $imap };
	$OPT{Server} = $imap->sockhost;
	$OPT{Port} = $imap->sockport;

	# not using multiple workers, here, since we want to increase
	# the chance of tripping concurrency bugs within PublicInbox/IMAP*.pm
	my $cmd = [ '-imapd', "--stdout=$out", "--stderr=$err", '-W0' ];
	push @$cmd, '-limap://'.$imap->sockhost.':'.$imap->sockport;
	if ($test_tls) {
		my $imaps = tcp_server();
		$rdr->{4} = $imaps;
		push @$cmd, '-limaps://'.$imaps->sockhost.':'.$imaps->sockport;
		push @$cmd, "--cert=$cert", "--key=$key";
		my $tls_opt = [
			SSL_hostname => 'server.local',
			SSL_verifycn_name => 'server.local',
			SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER(),
			SSL_ca_file => 'certs/test-ca.pem',
		];
		%STARTTLS_OPT = (%OPT, Starttls => $tls_opt);
		%IMAPS_OPT = (%OPT, Ssl => $tls_opt,
			Server => $imaps->sockhost,
			Port => $imaps->sockport
		);
	}
	print STDERR "# CMD ". join(' ', @$cmd). "\n";
	my $env = { PI_CONFIG => $pi_config };
	$td = start_script($cmd, $env, $rdr);
};
} # BEGIN
