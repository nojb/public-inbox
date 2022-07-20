#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
use PublicInbox::TestCommon;
use Socket qw(IPPROTO_TCP SOL_SOCKET);
# Net::POP3 is part of the standard library, but distros may split it off...
require_mods(qw(DBD::SQLite Net::POP3 IO::Socket::SSL File::FcntlLock));
require_git('2.6'); # for v2
use_ok 'IO::Socket::SSL';
use_ok 'PublicInbox::TLS';
my ($tmpdir, $for_destroy) = tmpdir();
mkdir("$tmpdir/p3state") or xbail "mkdir: $!";
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $olderr = "$tmpdir/plain.err";
my $group = 'test-pop3';
my $addr = $group . '@example.com';
my $stls = tcp_server();
my $plain = tcp_server();
my $pop3s = tcp_server();
my $patch = eml_load('t/data/0001.patch');
my $ibx = create_inbox 'pop3d', version => 2, -primary_address => $addr,
			indexlevel => 'basic', sub {
	my ($im, $ibx) = @_;
	$im->add(eml_load('t/plack-qp.eml')) or BAIL_OUT '->add';
	$im->add($patch) or BAIL_OUT '->add';
};
my $pi_config = "$tmpdir/pi_config";
open my $fh, '>', $pi_config or BAIL_OUT "open: $!";
print $fh <<EOF or BAIL_OUT "print: $!";
[publicinbox]
	pop3state = $tmpdir/p3state
[publicinbox "pop3"]
	inboxdir = $ibx->{inboxdir}
	address = $addr
	indexlevel = basic
	newsgroup = $group
EOF
close $fh or BAIL_OUT "close: $!\n";

my $pop3s_addr = tcp_host_port($pop3s);
my $stls_addr = tcp_host_port($stls);
my $plain_addr = tcp_host_port($plain);
my $env = { PI_CONFIG => $pi_config };
my $cert = 'certs/server-cert.pem';
my $key = 'certs/server-key.pem';

unless (-r $key && -r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run $^X ./create-certs.perl in certs/";
}

my $old = start_script(['-pop3d', '-W0',
	"--stdout=$tmpdir/plain.out", "--stderr=$olderr" ],
	$env, { 3 => $plain });
my @old_args = ($plain->sockhost, Port => $plain->sockport);
my $oldc = Net::POP3->new(@old_args);
my $locked_mb = ('e'x32)."\@$group";
ok($oldc->apop("$locked_mb.0", 'anonymous'), 'APOP to old');

{ # locking within the same process
	my $x = Net::POP3->new(@old_args);
	ok(!$x->apop("$locked_mb.0", 'anonymous'), 'APOP lock failure');
	like($x->message, qr/unable to lock/, 'diagnostic message');

	$x = Net::POP3->new(@old_args);
	ok($x->apop($locked_mb, 'anonymous'), 'APOP lock acquire');

	my $y = Net::POP3->new(@old_args);
	ok(!$y->apop($locked_mb, 'anonymous'), 'APOP lock fails once');

	undef $x;
	$y = Net::POP3->new(@old_args);
	ok($y->apop($locked_mb, 'anonymous'), 'APOP lock works after release');
}

for my $args (
	[ "--cert=$cert", "--key=$key",
		"-lpop3s://$pop3s_addr",
		"-lpop3://$stls_addr" ],
) {
	for ($out, $err) { open my $fh, '>', $_ or BAIL_OUT "truncate: $!" }
	my $cmd = [ '-netd', '-W0', @$args, "--stdout=$out", "--stderr=$err" ];
	my $td = start_script($cmd, $env, { 3 => $stls, 4 => $pop3s });

	my %o = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	# start negotiating a slow TLS connection
	my $slow = tcp_connect($pop3s, Blocking => 0);
	$slow = IO::Socket::SSL->start_SSL($slow, SSL_startHandshake => 0, %o);
	my $slow_done = $slow->connect_SSL;
	my @poll;
	if ($slow_done) {
		diag('W: connect_SSL early OK, slow client test invalid');
		use PublicInbox::Syscall qw(EPOLLIN EPOLLOUT);
		@poll = (fileno($slow), EPOLLIN | EPOLLOUT);
	} else {
		@poll = (fileno($slow), PublicInbox::TLS::epollbit());
	}

	my @p3s_args = ($pop3s->sockhost,
			Port => $pop3s->sockport, SSL => 1, %o);
	my $p3s = Net::POP3->new(@p3s_args);
	ok($p3s->quit, 'QUIT works w/POP3S');
	{
		$p3s = Net::POP3->new(@p3s_args);
		ok(!$p3s->apop("$locked_mb.0", 'anonymous'),
			'APOP lock failure w/ another daemon');
		like($p3s->message, qr/unable to lock/, 'diagnostic message');
	}

	# slow TLS connection did not block the other fast clients while
	# connecting, finish it off:
	until ($slow_done) {
		IO::Poll::_poll(-1, @poll);
		$slow_done = $slow->connect_SSL and last;
		@poll = (fileno($slow), PublicInbox::TLS::epollbit());
	}
	$slow->blocking(1);
	ok(sysread($slow, my $greet, 4096) > 0, 'slow got a greeting');
	my @np3_args = ($stls->sockhost, Port => $stls->sockport);
	my $np3 = Net::POP3->new(@np3_args);
	ok($np3->quit, 'plain QUIT works');
	$np3 = Net::POP3->new(@np3_args, %o);
	ok($np3->starttls, 'STLS works');
	ok($np3->quit, 'QUIT works after STLS');

	for my $mailbox (('x'x32)."\@$group", $group, ('a'x32)."\@z.$group") {
		$np3 = Net::POP3->new(@np3_args);
		ok(!$np3->user($mailbox), "USER $mailbox reject");
		ok($np3->quit, 'QUIT after USER fail');

		$np3 = Net::POP3->new(@np3_args);
		ok(!$np3->apop($mailbox, 'anonymous'), "APOP $mailbox reject");
		ok($np3->quit, "QUIT after APOP fail $mailbox");
	}
	for my $mailbox ($group, "$group.0") {
		my $u = ('f'x32)."\@$mailbox";
		$np3 = Net::POP3->new(@np3_args);
		ok($np3->user($u), "UUID\@$mailbox accept");
		ok($np3->pass('anonymous'), 'pass works');

		$np3 = Net::POP3->new(@np3_args);
		ok($np3->user($u), "UUID\@$mailbox accept");
		ok($np3->pass('anonymous'), 'pass works');

		my $list = $np3->list;
		my $uidl = $np3->uidl;
		is_deeply([sort keys %$list], [sort keys %$uidl],
			'LIST and UIDL keys match');
		ok($_ > 0, 'bytes in LIST result') for values %$list;
		like($_, qr/\A[a-z0-9]{40,}\z/,
			'blob IDs in UIDL result') for values %$uidl;

		$np3 = Net::POP3->new(@np3_args);
		ok(!$np3->apop($u, 'anonumuss'), 'APOP wrong pass reject');

		$np3 = Net::POP3->new(@np3_args);
		ok($np3->apop($u, 'anonymous'), "APOP UUID\@$mailbox");
		my @res = $np3->popstat;
		is($res[0], 2, 'STAT knows about 2 messages');

		my $msg = $np3->get(2);
		$msg = join('', @$msg);
		$msg =~ s/\r\n/\n/g;
		is_deeply(PublicInbox::Eml->new($msg), $patch,
			't/data/0001.patch round-tripped');

		ok(!$np3->get(22), 'missing message');

		$msg = $np3->top(2, 0);
		$msg = join('', @$msg);
		$msg =~ s/\r\n/\n/g;
		is($msg, $patch->header_obj->as_string . "\n",
			'TOP numlines=0');

		ok(!$np3->top(2, -1), 'negative TOP numlines');

		$msg = $np3->top(2, 1);
		$msg = join('', @$msg);
		$msg =~ s/\r\n/\n/g;
		is($msg, $patch->header_obj->as_string . <<EOF,

Filenames within a project tend to be reasonably stable within a
EOF
			'TOP numlines=1');

		$msg = $np3->top(2, 10000);
		$msg = join('', @$msg);
		$msg =~ s/\r\n/\n/g;
		is_deeply(PublicInbox::Eml->new($msg), $patch,
			'TOP numlines=10000 (excess)');

		$np3 = Net::POP3->new(@np3_args, %o);
		ok($np3->starttls, 'STLS works before APOP');
		ok($np3->apop($u, 'anonymous'), "APOP UUID\@$mailbox w/ STLS");

		# undocumented:
		ok($np3->_NOOP, 'NOOP works') if $np3->can('_NOOP');
	}

	SKIP: {
		skip 'TCP_DEFER_ACCEPT is Linux-only', 2 if $^O ne 'linux';
		my $var = eval { Socket::TCP_DEFER_ACCEPT() } // 9;
		my $x = getsockopt($pop3s, IPPROTO_TCP, $var) //
			xbail "IPPROTO_TCP: $!";
		ok(unpack('i', $x) > 0, 'TCP_DEFER_ACCEPT set on POP3S');
		$x = getsockopt($stls, IPPROTO_TCP, $var) //
			xbail "IPPROTO_TCP: $!";
		is(unpack('i', $x), 0, 'TCP_DEFER_ACCEPT is 0 on plain POP3');
	};
	SKIP: {
		skip 'SO_ACCEPTFILTER is FreeBSD-only', 2 if $^O ne 'freebsd';
		system('kldstat -m accf_data >/dev/null') and
			skip 'accf_data not loaded? kldload accf_data', 2;
		require PublicInbox::Daemon;
		my $x = getsockopt($pop3s, SOL_SOCKET,
				$PublicInbox::Daemon::SO_ACCEPTFILTER);
		like($x, qr/\Adataready\0+\z/, 'got dataready accf for pop3s');
		$x = getsockopt($stls, IPPROTO_TCP,
				$PublicInbox::Daemon::SO_ACCEPTFILTER);
		is($x, undef, 'no BSD accept filter for plain IMAP');
	};

	$td->kill;
	$td->join;
	is($?, 0, 'no error in exited -netd');
	open my $fh, '<', $err or BAIL_OUT "open $err failed: $!";
	my $eout = do { local $/; <$fh> };
	unlike($eout, qr/wide/i, 'no Wide character warnings in -netd');
}

{
	my $capa = $oldc->capa;
	ok(defined($capa->{PIPELINING}), 'pipelining supported by CAPA');
	is($capa->{EXPIRE}, 0, 'EXPIRE 0 set');

	# clients which see "EXPIRE 0" can elide DELE requests
	my $list = $oldc->list;
	ok($oldc->get($_), "RETR $_") for keys %$list;
	ok($oldc->quit, 'QUIT after RETR');

	$oldc = Net::POP3->new(@old_args);
	ok($oldc->apop("$locked_mb.0", 'anonymous'), 'APOP reconnect');
	my $cont = $oldc->list;
	is_deeply($cont, {}, 'no messages after implicit DELE from EXPIRE 0');
	ok($oldc->quit, 'QUIT on noop');

	# test w/o checking CAPA to trigger EXPIRE 0
	$oldc = Net::POP3->new(@old_args);
	ok($oldc->apop($locked_mb, 'anonymous'), 'APOP on latest slice');
	my $l2 = $oldc->list;
	is_deeply($l2, $list, 'different mailbox, different deletes');
	ok($oldc->get($_), "RETR $_") for keys %$list;
	ok($oldc->quit, 'QUIT w/o EXPIRE nor DELE');

	$oldc = Net::POP3->new(@old_args);
	ok($oldc->apop($locked_mb, 'anonymous'), 'APOP again on latest');
	$l2 = $oldc->list;
	is_deeply($l2, $list, 'no DELE nor EXPIRE preserves messages');
	ok($oldc->delete(2), 'explicit DELE on latest');
	ok($oldc->quit, 'QUIT w/ highest DELE');

	# this is non-standard behavior, but necessary if we expect hundreds
	# of thousands of users on cheap HW
	$oldc = Net::POP3->new(@old_args);
	ok($oldc->apop($locked_mb, 'anonymous'), 'APOP yet again on latest');
	is_deeply($oldc->list, {}, 'highest DELE deletes older messages, too');
}

# TODO: more tests, but mpop was really helpful in helping me
# figure out bugs with larger newsgroups (>50K messages) which
# probably isn't suited for this test suite.

$old->kill;
$old->join;
is($?, 0, 'no error in exited -pop3d');
open $fh, '<', $olderr or BAIL_OUT "open $olderr failed: $!";
my $eout = do { local $/; <$fh> };
unlike($eout, qr/wide/i, 'no Wide character warnings in -pop3d');

done_testing;
