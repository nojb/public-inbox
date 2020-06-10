#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
require_mods('Data::Dumper');
Data::Dumper->import('Dumper');
my $inboxdir = $ENV{GIANT_INBOX_DIR};
(defined($inboxdir) && -d $inboxdir) or
	plan skip_all => "GIANT_INBOX_DIR not defined for $0";
plan skip_all => "bad characters in $inboxdir" if $inboxdir =~ m![^\w\.\-/]!;
my ($tmpdir, $for_destroy) = tmpdir();
my $cfg = "$tmpdir/cfg";
my $mailbox = 'inbox.test';
{
	open my $fh, '>', $cfg or BAIL_OUT "open: $!";
	print $fh <<EOF or BAIL_OUT "print: $!";
[publicinbox "test"]
	newsgroup = $mailbox
	address = test\@example.com
	inboxdir = $inboxdir
EOF
	close $fh or BAIL_OUT "close: $!";
}
my ($out, $err) = ("$tmpdir/stdout.log", "$tmpdir/stderr.log");
my $sock = tcp_server();
my $cmd = [ '-imapd', '-W0', "--stdout=$out", "--stderr=$err"];
my $env = { PI_CONFIG => $cfg };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT "-imapd: $?";
my ($host, $port) = ($sock->sockhost, $sock->sockport);
my $c = tcp_connect($sock);
like(readline($c), qr/CAPABILITY /, 'got greeting');
undef $c;

SKIP: {
	require_mods('Mail::IMAPClient', 3);
	unless ($ENV{RT_132720_FIXED}) {
		my $bug = 'https://rt.cpan.org/Ticket/Display.html?id=132720';
		skip "<$bug>, RT_132720_FIXED not defined", 3;
	}
	my %opt = (Server => $host, Port => $port,
			User => 'u', Password => 'p', Clear => 1);
	my $uc = Mail::IMAPClient->new(%opt);
	my $c = Mail::IMAPClient->new(%opt);
	ok($c->compress, 'enabled compression');
	ok $c->examine($mailbox), 'compressed EXAMINE-ed';
	ok $uc->examine($mailbox), 'uncompress EXAMINE-ed';
	my $range = $uc->search('all');
	for my $uid (@$range) {
		my $A = $uc->fetch_hash($uid, 'BODY[]');
		my $B = $c->fetch_hash($uid, 'BODY[]');
		if (!is_deeply($A, $B, "$uid identical")) {
			diag Dumper([$A, $B]);
			diag Dumper([$uc, $c]);
			last;
		}
	}
	$uc->logout;
	$c->logout;
}

SKIP: {
	require_mods('Mail::IMAPTalk', 3);
	my %opt = (Server => $host, Port => $port, UseSSL => 0,
		Username => 'u', Password => 'p', Uid => 1);
	my $uc = Mail::IMAPTalk->new(%opt) or BAIL_OUT 'IMAPTalk->new';
	my $c = Mail::IMAPTalk->new(%opt, UseCompress => 1) or
		BAIL_OUT 'IMAPTalk->new(UseCompress => 1)';
	ok $c->examine($mailbox), 'compressed EXAMINE-ed';
	ok $uc->examine($mailbox), 'uncompress EXAMINE-ed';
	my $range = $uc->search('all');
	for my $uid (@$range) {
		my $A = $uc->fetch($uid, 'rfc822');
		my $B = $c->fetch($uid, 'rfc822');
		if (!is_deeply($A, $B, "$uid identical")) {
			diag Dumper([$A, $B]);
			diag Dumper([$uc, $c]);
			last;
		}
	}
}
done_testing;
