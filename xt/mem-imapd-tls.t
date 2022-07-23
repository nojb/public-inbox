#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Idle client memory usage test, particularly after EXAMINE when
# Message Sequence Numbers are loaded
use strict;
use v5.10.1;
use Socket qw(SOCK_STREAM IPPROTO_TCP SOL_SOCKET);
use PublicInbox::TestCommon;
use PublicInbox::Syscall qw(:epoll);
use PublicInbox::DS;
require_mods(qw(-imapd));
my $inboxdir = $ENV{GIANT_INBOX_DIR};
my $TEST_TLS;
SKIP: {
	require_mods('IO::Socket::SSL', 1);
	$TEST_TLS = $ENV{TEST_TLS} // 1;
};
plan skip_all => "GIANT_INBOX_DIR not defined for $0" unless $inboxdir;
diag 'TEST_COMPRESS='.($ENV{TEST_COMPRESS} // 1) . " TEST_TLS=$TEST_TLS";

my ($cert, $key) = qw(certs/server-cert.pem certs/server-key.pem);
if ($TEST_TLS) {
	if (!-r $key || !-r $cert) {
		plan skip_all =>
			"certs/ missing for $0, run ./certs/create-certs.perl";
	}
	use_ok 'PublicInbox::TLS';
}
my ($tmpdir, $for_destroy) = tmpdir();
my ($out, $err) = ("$tmpdir/stdout.log", "$tmpdir/stderr.log");
my $pi_config = "$tmpdir/pi_config";
my $group = 'inbox.test';
local $SIG{PIPE} = 'IGNORE'; # for IMAPC (below)
my $imaps = tcp_server();
{
	open my $fh, '>', $pi_config or die "open: $!\n";
	print $fh <<EOF or die;
[publicinbox "imapd-tls"]
	inboxdir = $inboxdir
	address = $group\@example.com
	newsgroup = $group
	indexlevel = basic
EOF
	close $fh or die "close: $!\n";
}
my $imaps_addr = tcp_host_port($imaps);
my $env = { PI_CONFIG => $pi_config };
my $arg = $TEST_TLS ? [ "-limaps://$imaps_addr/?cert=$cert,key=$key" ] : [];
my $cmd = [ '-imapd', '-W0', @$arg, "--stdout=$out", "--stderr=$err" ];

# run_mode=0 ensures Test::More FDs don't get shared
my $td = start_script($cmd, $env, { 3 => $imaps, run_mode => 0 });
my %ssl_opt;
if ($TEST_TLS) {
	%ssl_opt = (
		SSL_hostname => 'server.local',
		SSL_verifycn_name => 'server.local',
		SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER(),
		SSL_ca_file => 'certs/test-ca.pem',
	);
	my $ctx = IO::Socket::SSL::SSL_Context->new(%ssl_opt);

	# cf. https://rt.cpan.org/Ticket/Display.html?id=129463
	my $mode = eval { Net::SSLeay::MODE_RELEASE_BUFFERS() };
	if ($mode && $ctx->{context}) {
		eval { Net::SSLeay::CTX_set_mode($ctx->{context}, $mode) };
		warn "W: $@ (setting SSL_MODE_RELEASE_BUFFERS)\n" if $@;
	}

	$ssl_opt{SSL_reuse_ctx} = $ctx;
	$ssl_opt{SSL_startHandshake} = 0;
}
chomp(my $nfd = `/bin/sh -c 'ulimit -n'`);
$nfd -= 10;
ok($nfd > 0, 'positive FD count');
my $MAX_FD = 10000;
$nfd = $MAX_FD if $nfd >= $MAX_FD;
our $DONE = 0;
sub once { 0 }; # stops event loop

# setup the event loop so that it exits at every step
# while we're still doing connect(2)
PublicInbox::DS->SetLoopTimeout(0);
PublicInbox::DS->SetPostLoopCallback(\&once);
my $pid = $td->{pid};
if ($^O eq 'linux' && open(my $f, '<', "/proc/$pid/status")) {
	diag(grep(/RssAnon/, <$f>));
}

foreach my $n (1..$nfd) {
	my $io = tcp_connect($imaps, Blocking => 0);
	$io = IO::Socket::SSL->start_SSL($io, %ssl_opt) if $TEST_TLS;
	IMAPC->new($io);

	# one step through the event loop
	# do a little work as we connect:
	PublicInbox::DS::event_loop();

	# try not to overflow the listen() backlog:
	if (!($n % 128) && $DONE != $n) {
		diag("nr: ($n) $DONE/$nfd");
		PublicInbox::DS->SetLoopTimeout(-1);
		PublicInbox::DS->SetPostLoopCallback(sub { $DONE != $n });

		# clear the backlog:
		PublicInbox::DS::event_loop();

		# resume looping
		PublicInbox::DS->SetLoopTimeout(0);
		PublicInbox::DS->SetPostLoopCallback(\&once);
	}
}

# run the event loop normally, now:
diag "done?: @".time." $DONE/$nfd";
if ($DONE != $nfd) {
	PublicInbox::DS->SetLoopTimeout(-1);
	PublicInbox::DS->SetPostLoopCallback(sub { $DONE != $nfd });
	PublicInbox::DS::event_loop();
}
is($nfd, $DONE, "$nfd/$DONE done");
if ($^O eq 'linux' && open(my $f, '<', "/proc/$pid/status")) {
	diag(grep(/RssAnon/, <$f>));
	diag "  SELF lsof | wc -l ".`lsof -p $$ |wc -l`;
	diag "SERVER lsof | wc -l ".`lsof -p $pid |wc -l`;
}
PublicInbox::DS->Reset;
$td->kill;
$td->join;
is($?, 0, 'no error in exited process');
done_testing;

package IMAPC;
use strict;
use parent qw(PublicInbox::DS);
# fields: step: state machine, zin: Zlib inflate context
use PublicInbox::Syscall qw(EPOLLIN EPOLLOUT EPOLLONESHOT);
use Errno qw(EAGAIN);
# determines where we start event_step
use constant FIRST_STEP => ($ENV{TEST_COMPRESS} // 1) ? -2 : 0;

# return true if complete, false if incomplete (or failure)
sub connect_tls_step {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	return 1 if $sock->connect_SSL;
	return $self->drop("$!") if $! != EAGAIN;
	if (my $ev = PublicInbox::TLS::epollbit()) {
		unshift @{$self->{wbuf}}, \&connect_tls_step;
		PublicInbox::DS::epwait($sock, $ev | EPOLLONESHOT);
		0;
	} else {
		$self->drop('BUG? EAGAIN but '.PublicInbox::TLS::err());
	}
}

sub event_step {
	my ($self) = @_;

	# TLS negotiation happens in flush_write via {wbuf}
	return unless $self->flush_write && $self->{sock};

	if ($self->{step} == -2) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A\* OK / or die 'no greeting';
		$self->{step} = -1;
		$self->write(\"1 COMPRESS DEFLATE\r\n");
	}
	if ($self->{step} == -1) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A1 OK / or die "no compression $buf";
		IMAPCdeflate->enable($self);
		$self->{step} = 1;
		$self->write(\"2 EXAMINE inbox.test.0\r\n");
	}
	if ($self->{step} == 0) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A\* OK / or die 'no greeting';
		$self->{step} = 1;
		$self->write(\"2 EXAMINE inbox.test.0\r\n");
	}
	if ($self->{step} == 1) {
		my $buf = '';
		until ($buf =~ /^2 OK \[READ-ONLY/ms) {
			$self->do_read(\$buf, 4096, length($buf)) or return;
		}
		$self->{step} = 2;
		$self->write(\"3 UID FETCH 1 (UID FLAGS)\r\n");
	}
	if ($self->{step} == 2) {
		my $buf = '';
		until ($buf =~ /^3 OK /ms) {
			$self->do_read(\$buf, 4096, length($buf)) or return;
		}
		$self->{step} = 3;
		$self->write(\"4 IDLE\r\n");
	}
	if ($self->{step} == 3) {
		$self->do_read(\(my $buf = ''), 128) or return;
		no warnings 'once';
		$::DONE++;
		$self->{step} = 5; # all done
	} else {
		warn "$self->{step} Should never get here $self";
	}
}

sub new {
	my ($class, $io) = @_;
	my $self = bless { step => FIRST_STEP }, $class;
	if ($io->can('connect_SSL')) {
		$self->{wbuf} = [ \&connect_tls_step ];
	}
	# wait for connect(), and maybe SSL_connect()
	$self->SUPER::new($io, EPOLLOUT|EPOLLONESHOT);
}

1;
package IMAPCdeflate;
use strict;
our @ISA;
use Compress::Raw::Zlib;
use PublicInbox::IMAP;
my %ZIN_OPT;
BEGIN {
	@ISA = qw(IMAPC);
	%ZIN_OPT = ( -WindowBits => -15, -AppendOutput => 1 );
	*write = \&PublicInbox::IMAPdeflate::write;
	*do_read = \&PublicInbox::IMAPdeflate::do_read;
};

sub enable {
	my ($class, $self) = @_;
	my ($in, $err) = Compress::Raw::Zlib::Inflate->new(%ZIN_OPT);
	die "Inflate->new failed: $err" if $err != Z_OK;
	bless $self, $class;
	$self->{zin} = $in;
}

1;
