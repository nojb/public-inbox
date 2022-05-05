#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12;
use Socket qw(IPPROTO_TCP SOL_SOCKET);
use PublicInbox::TestCommon;
# IO::Poll and Net::NNTP are part of the standard library, but
# distros may split them off...
require_mods(qw(-imapd IO::Socket::SSL Mail::IMAPClient IO::Poll Net::NNTP));
my $imap_client = 'Mail::IMAPClient';
$imap_client->can('starttls') or
	plan skip_all => 'Mail::IMAPClient does not support TLS';
Net::NNTP->can('starttls') or
	plan skip_all => 'Net::NNTP does not support TLS';
my $cert = 'certs/server-cert.pem';
my $key = 'certs/server-key.pem';
unless (-r $key && -r $cert) {
	plan skip_all =>
		"certs/ missing for $0, run $^X ./create-certs.perl in certs/";
}
use_ok 'PublicInbox::TLS';
use_ok 'IO::Socket::SSL';
require_git('2.6');

my ($tmpdir, $for_destroy) = tmpdir();
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $pi_config;
my $group = 'test-netd';
my $addr = $group . '@example.com';

# ensure we have free, low-numbered contiguous FDs from 3.. FD inheritance
my @pad_pipes;
for (1..3) {
	pipe(my ($r, $w)) or xbail "pipe: $!";
	push @pad_pipes, $r, $w;
};
my %srv = map { $_ => tcp_server() } qw(imap nntp imaps nntps);
my $ibx = create_inbox 'netd', version => 2,
			-primary_address => $addr, indexlevel => 'basic', sub {
	my ($im, $ibx) = @_;
	$im->add(eml_load('t/data/0001.patch')) or BAIL_OUT '->add';
	$pi_config = "$ibx->{inboxdir}/pi_config";
	open my $fh, '>', $pi_config or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT "print: $!";
[publicinbox "netd"]
	inboxdir = $ibx->{inboxdir}
	address = $addr
	indexlevel = basic
	newsgroup = $group
EOF
	close $fh or BAIL_OUT "close: $!\n";
};
$pi_config //= "$ibx->{inboxdir}/pi_config";
my @args = ("--cert=$cert", "--key=$key");
my $rdr = {};
my $fd = 3;
while (my ($k, $v) = each %srv) {
	push @args, "-l$k://".tcp_host_port($v);
	$rdr->{$fd++} = $v;
}
my $cmd = [ '-netd', '-W0', @args, "--stdout=$out", "--stderr=$err" ];
my $env = { PI_CONFIG => $pi_config };
my $td = start_script($cmd, $env, $rdr);
@pad_pipes = ();
undef $rdr;
my %o = (
	SSL_hostname => 'server.local',
	SSL_verifycn_name => 'server.local',
	SSL_verify_mode => SSL_VERIFY_PEER(),
	SSL_ca_file => 'certs/test-ca.pem',
);
{
	my $c = tcp_connect($srv{imap});
	my $msg = <$c>;
	like($msg, qr/IMAP4rev1/, 'connected to IMAP');
}
{
	my $c = tcp_connect($srv{nntp});
	my $msg = <$c>;
	like($msg, qr/^201 .*? ready - post via email/, 'connected to NNTP');
}

# TODO: more tests
done_testing;
