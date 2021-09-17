#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(lei));
use File::Path qw(remove_tree);

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
});

done_testing;
