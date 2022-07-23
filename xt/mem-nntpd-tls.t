#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Idle client memory usage test
use v5.12.1;
use PublicInbox::TestCommon;
use File::Temp qw(tempdir);
use Socket qw(SOCK_STREAM IPPROTO_TCP SOL_SOCKET);
require_mods(qw(-nntpd));
require PublicInbox::InboxWritable;
require PublicInbox::SearchIdx;
use PublicInbox::Syscall qw(:epoll);
use PublicInbox::DS;
my $version = 2; # v2 needs newer git
require_git('2.6') if $version >= 2;
use_ok 'IO::Socket::SSL';
my ($cert, $key) = qw(certs/server-cert.pem certs/server-key.pem);
unless (-r $key && -r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run ./certs/create-certs.perl";
}
use_ok 'PublicInbox::TLS';
my ($tmpdir, $for_destroy) = tmpdir();
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $mainrepo = $tmpdir;
my $pi_config = "$tmpdir/pi_config";
my $group = 'test-nntpd-tls';
my $addr = $group . '@example.com';
local $SIG{PIPE} = 'IGNORE'; # for NNTPC (below)
my $nntps = tcp_server();
my $ibx = PublicInbox::Inbox->new({
	inboxdir => $mainrepo,
	name => 'nntpd-tls',
	version => $version,
	-primary_address => $addr,
	indexlevel => 'basic',
});
$ibx = PublicInbox::InboxWritable->new($ibx, {nproc=>1});
$ibx->init_inbox(0);
{
	open my $fh, '>', $pi_config or die "open: $!\n";
	print $fh <<EOF
[publicinbox "nntpd-tls"]
	mainrepo = $mainrepo
	address = $addr
	indexlevel = basic
	newsgroup = $group
EOF
	;
	close $fh or die "close: $!\n";
}

{
	my $im = $ibx->importer(0);
	my $eml = eml_load('t/data/0001.patch');
	ok($im->add($eml), 'message added');
	$im->done;
	if ($version == 1) {
		my $s = PublicInbox::SearchIdx->new($ibx, 1);
		$s->index_sync;
	}
}

my $nntps_addr = tcp_host_port($nntps);
my $env = { PI_CONFIG => $pi_config };
my $tls = $ENV{TLS} // 1;
my $args = $tls ? ["--cert=$cert", "--key=$key", "-lnntps://$nntps_addr"] : [];
my $cmd = [ '-nntpd', '-W0', @$args, "--stdout=$out", "--stderr=$err" ];

# run_mode=0 ensures Test::More FDs don't get shared
my $td = start_script($cmd, $env, { 3 => $nntps, run_mode => 0 });
my %ssl_opt = (
	SSL_hostname => 'server.local',
	SSL_verifycn_name => 'server.local',
	SSL_verify_mode => SSL_VERIFY_PEER(),
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

my %opt = (
	Proto => 'tcp',
	PeerAddr => $nntps_addr,
	Type => SOCK_STREAM,
	Blocking => 0
);
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

foreach my $n (1..$nfd) {
	my $io = tcp_connect($nntps, Blocking => 0);
	$io = IO::Socket::SSL->start_SSL($io, %ssl_opt) if $tls;
	NNTPC->new($io);

	# one step through the event loop
	# do a little work as we connect:
	PublicInbox::DS::event_loop();

	# try not to overflow the listen() backlog:
	if (!($n % 128) && $n != $DONE) {
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
my $pid = $td->{pid};
my $dump_rss = sub {
	return if $^O ne 'linux';
	open(my $f, '<', "/proc/$pid/status") or return;
	diag(grep(/RssAnon/, <$f>));
};
$dump_rss->();

# run the event loop normally, now:
if ($DONE != $nfd) {
	PublicInbox::DS->SetLoopTimeout(-1);
	PublicInbox::DS->SetPostLoopCallback(sub {
		diag "done: ".time." $DONE";
		$DONE != $nfd;
	});
	PublicInbox::DS::event_loop();
}

is($nfd, $DONE, 'done');
$dump_rss->();
if ($^O eq 'linux') {
	diag "  SELF lsof | wc -l ".`lsof -p $$ |wc -l`;
	diag "SERVER lsof | wc -l ".`lsof -p $pid |wc -l`;
}
PublicInbox::DS->Reset;
$td->kill;
$td->join;
is($?, 0, 'no error in exited process');
done_testing();

package NNTPC;
use v5.12;
use parent qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLIN EPOLLOUT EPOLLONESHOT);
use Data::Dumper;

# return true if complete, false if incomplete (or failure)
sub connect_tls_step ($) {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	return 1 if $sock->connect_SSL;
	return $self->drop("$!") unless $!{EAGAIN};
	if (my $ev = PublicInbox::TLS::epollbit()) {
		unshift @{$self->{wbuf}}, \&connect_tls_step;
		PublicInbox::DS::epwait($self->{sock}, $ev | EPOLLONESHOT);
		0;
	} else {
		$self->drop('BUG? EAGAIN but '.PublicInbox::TLS::err());
	}
}

sub event_step ($) {
	my ($self) = @_;

	# TLS negotiation happens in flush_write via {wbuf}
	return unless $self->flush_write && $self->{sock};

	if ($self->{step} == -2) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A201 / or die "no greeting";
		$self->{step} = -1;
		$self->write(\"COMPRESS DEFLATE\r\n");
	}
	if ($self->{step} == -1) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A20[0-9] / or die "no compression $buf";
		NNTPCdeflate->enable($self);
		$self->{step} = 1;
		$self->write(\"DATE\r\n");
	}
	if ($self->{step} == 0) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A201 / or die "no greeting";
		$self->{step} = 1;
		$self->write(\"DATE\r\n");
	}
	if ($self->{step} == 1) {
		$self->do_read(\(my $buf = ''), 128) or return;
		$buf =~ /\A111 / or die 'no date';
		no warnings 'once';
		$::DONE++;
		$self->{step} = 2; # all done
	} else {
		die "$self->{step} Should never get here ". Dumper($self);
	}
}

sub new {
	my ($class, $io) = @_;
	my $self = bless {}, $class;

	# wait for connect(), and maybe SSL_connect()
	$self->SUPER::new($io, EPOLLOUT|EPOLLONESHOT);
	$self->{wbuf} = [ \&connect_tls_step ] if $io->can('connect_SSL');
	$self->{step} = -2; # determines where we start event_step
	$self;
};

1;
package NNTPCdeflate;
use v5.12;
our @ISA = qw(NNTPC PublicInbox::DS);
use Compress::Raw::Zlib;
use PublicInbox::DSdeflate;
BEGIN {
	*write = \&PublicInbox::DSdeflate::write;
	*do_read = \&PublicInbox::DSdeflate::do_read;
	*event_step = \&NNTPC::event_step;
	*flush_write = \&PublicInbox::DS::flush_write;
	*close = \&PublicInbox::DS::close;
}

sub enable {
	my ($class, $self) = @_;
	my %ZIN_OPT = ( -WindowBits => -15, -AppendOutput => 1 );
	my ($in, $err) = Compress::Raw::Zlib::Inflate->new(%ZIN_OPT);
	die "Inflate->new failed: $err" if $err != Z_OK;
	bless $self, $class;
	$self->{zin} = $in;
}

1;
