#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian Net::NNTP));
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $sock = tcp_server;
my $cmd = [ '-nntpd', '-W0', "--stdout=$tmpdir/1", "--stderr=$tmpdir/2" ];
my $env = { PI_CONFIG => $cfg_path };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-nntpd $?");
my $host_port = tcp_host_port($sock);
undef $sock;
test_lei({ tmpdir => $tmpdir }, sub {
	lei_ok(qw(q z:1..));
	my $out = json_utf8->decode($lei_out);
	is_deeply($out, [ undef ], 'nothing imported, yet');
	lei_ok('import', "nntp://$host_port/t.v2");
	diag $lei_err;
	lei_ok(qw(q z:1..));
	diag $lei_err;
	$out = json_utf8->decode($lei_out);
	ok(scalar(@$out) > 1, 'got imported messages');
	is(pop @$out, undef, 'trailing JSON null element was null');
	my %r;
	for (@$out) { $r{ref($_)}++ }
	is_deeply(\%r, { 'HASH' => scalar(@$out) }, 'all hashes');

	my $f = "$ENV{HOME}/.local/share/lei/store/mail_sync.sqlite3";
	ok(-s $f, 'mail_sync exists tracked for redundant imports');
});
done_testing;
