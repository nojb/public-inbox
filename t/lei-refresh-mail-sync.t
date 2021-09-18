#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(lei));
use File::Path qw(remove_tree);
require Socket;

my $stop_daemon = sub { # needed since we don't have inotify
	lei_ok qw(daemon-pid);
	chomp(my $pid = $lei_out);
	$pid > 0 or xbail "bad pid: $pid";
	kill('TERM', $pid) or xbail "kill: $!";
	for (0..10) {
		tick;
		kill(0, $pid) or last;
	}
	kill(0, $pid) and xbail "daemon still running (PID:$pid)";
};

test_lei({ daemon_only => 1 }, sub {
	my $d = "$ENV{HOME}/d";
	my ($ro_home, $cfg_path) = setup_public_inboxes;
	lei_ok qw(daemon-pid);
	lei_ok qw(add-external), "$ro_home/t2";
	lei_ok qw(q mid:testmessage@example.com -o), "Maildir:$d";
	my (@o) = glob("$d/*/*");
	scalar(@o) == 1 or xbail('multiple results', \@o);
	my ($bn0) = ($o[0] =~ m!/([^/]+)\z!);

	my $oid = '9bf1002c49eb075df47247b74d69bcd555e23422';
	lei_ok 'inspect', "blob:$oid";
	my $before = json_utf8->decode($lei_out);
	my $exp0 = { 'mail-sync' => { "maildir:$d" => [ $bn0 ] } };
	is_deeply($before, $exp0, 'inspect shows expected');

	$stop_daemon->();
	my $dst = $o[0];
	$dst =~ s/:2,.*\z// and $dst =~ s!/cur/!/new/! and
		rename($o[0], $dst) or xbail "rename($o[0] => $dst): $!";

	lei_ok 'inspect', "blob:$oid";
	is_deeply(json_utf8->decode($lei_out),
		$before, 'inspect unchanged immediately after restart');
	lei_ok 'refresh-mail-sync', '--all';
	lei_ok 'inspect', "blob:$oid";
	my ($bn1) = ($dst =~ m!/([^/]+)\z!);
	my $exp1 = { 'mail-sync' => { "maildir:$d" => [ $bn1 ] } };
	is_deeply(json_utf8->decode($lei_out), $exp1,
		'refresh-mail-sync updated location');

	$stop_daemon->();
	rename($dst, "$d/unwatched") or xbail "rename $dst out-of-the-way $!";

	lei_ok 'refresh-mail-sync', $d;
	lei_ok 'inspect', "blob:$oid";
	is($lei_out, '{}', 'no known locations after "removal"');
	lei_ok 'refresh-mail-sync', "Maildir:$d";

	$stop_daemon->();
	rename("$d/unwatched", $dst) or xbail "rename $dst back";

	lei_ok 'refresh-mail-sync', "Maildir:$d";
	lei_ok 'inspect', "blob:$oid";
	is_deeply(json_utf8->decode($lei_out), $exp1,
		'replaced file noted again');

	$stop_daemon->();

	remove_tree($d);
	lei_ok 'refresh-mail-sync', '--all';
	lei_ok 'inspect', "blob:$oid";
	is($lei_out, '{}', 'no known locations after "removal"');
	lei_ok 'ls-mail-sync';
	is($lei_out, '', 'no sync left when folder is gone');

SKIP: {
	require_mods(qw(-imapd -nntpd Mail::IMAPClient Net::NNTP), 1);
	require File::Copy; # stdlib
	my $home = $ENV{HOME};
	my $srv;
	my $cfg_path2 = "$home/cfg2";
	File::Copy::cp($cfg_path, $cfg_path2);
	my $env = { PI_CONFIG => $cfg_path2 };
	my $sock_cls;
	for my $x (qw(imapd)) {
		my $s = tcp_server;
		$sock_cls //= ref($s);
		my $cmd = [ "-$x", '-W0', "--stdout=$home/$x.out",
			"--stderr=$home/$x.err" ];
		my $td = start_script($cmd, $env, { 3 => $s}) or xbail("-$x");
		$srv->{$x} = {
			addr => (my $scalar = tcp_host_port($s)),
			td => $td,
			cmd => $cmd,
		};
	}
	my $url = "imap://$srv->{imapd}->{addr}/t.v1.0";
	lei_ok 'import', $url, '+L:v1';
	lei_ok 'inspect', "blob:$oid";
	$before = json_utf8->decode($lei_out);
	my @f = grep(m!\Aimap://;AUTH=ANONYMOUS\@\Q$srv->{imapd}->{addr}\E!,
		keys %{$before->{'mail-sync'}});
	is(scalar(@f), 1, 'got IMAP folder') or xbail(\@f);
	xsys([qw(git config), '-f', $cfg_path2,
		qw(--unset publicinbox.t1.newsgroup)]) and
		xbail "git config $?";
	$stop_daemon->(); # drop IMAP IDLE
	$srv->{imapd}->{td}->kill('HUP');
	tick; # wait for HUP
	lei_ok 'refresh-mail-sync', $url;
	lei_ok 'inspect', "blob:$oid";
	my $after = json_utf8->decode($lei_out);
	ok(!$after->{'mail-sync'}, 'no sync info for non-existent mailbox');
	lei_ok 'ls-mail-sync';
	unlike $lei_out, qr!^\Q$f[0]\E!, 'IMAP folder gone from mail_sync';

	# simulate server downtime
	$url = "imap://$srv->{imapd}->{addr}/t.v2.0";
	lei_ok 'import', $url, '+L:v2';

	lei_ok 'inspect', "blob:$oid";
	$before = $lei_out;
	delete $srv->{imapd}->{td}; # kill + join daemon

	ok(!(lei 'refresh-mail-sync', $url), 'URL fails on dead -imapd');
	ok(!(lei 'refresh-mail-sync', '--all'), '--all fails on dead -imapd');

	# restart server (somewhat dangerous since we released the socket)
	my $listen = $sock_cls->new(
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		Listen => 1024,
		Blocking => 0,
		LocalAddr => $srv->{imapd}->{addr},
	) or xbail "$sock_cls->new: $!";
	my $cmd = $srv->{imapd}->{cmd};
	$srv->{imapd}->{td} = start_script($cmd, $env, { 3 => $listen }) or
		xbail "@$cmd";
	lei_ok 'refresh-mail-sync', '--all';
	lei_ok 'inspect', "blob:$oid";
	is($lei_out, $before, 'no changes when server was down');
}; # imapd+nntpd stuff
});

done_testing;
