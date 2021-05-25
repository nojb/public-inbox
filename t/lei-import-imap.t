#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(lei -imapd Mail::IMAPClient));
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $sock = tcp_server;
my $cmd = [ '-imapd', '-W0', "--stdout=$tmpdir/1", "--stderr=$tmpdir/2" ];
my $env = { PI_CONFIG => $cfg_path };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-imapd: $?");
my $host_port = tcp_host_port($sock);
undef $sock;
test_lei({ tmpdir => $tmpdir }, sub {
	my $url = "imap://$host_port/t.v2.0";

	lei_ok(qw(q z:1..));
	my $out = json_utf8->decode($lei_out);
	is_deeply($out, [ undef ], 'nothing imported, yet');

	lei_ok('inspect', $url);
	is_deeply(json_utf8->decode($lei_out), {}, 'no inspect stats, yet');

	lei_ok('import', $url);
	lei_ok('inspect', $url);
	my $res = json_utf8->decode($lei_out);
	is(scalar keys %$res, 1, 'got one key in inspect URL');
	my $re = qr!\Aimap://;AUTH=ANONYMOUS\@\Q$host_port\E
			/t\.v2\.0;UIDVALIDITY=\d+!x;
	like((keys %$res)[0], qr/$re\z/, 'got expanded key');

	lei_ok 'ls-mail-sync';
	like($lei_out, qr!$re\n\z!, 'ls-mail-sync');
	chomp(my $u = $lei_out);
	lei_ok('import', $u, \'UIDVALIDITY match in URL');
	$url = $u;
	$u =~ s/;UIDVALIDITY=(\d+)\s*/;UIDVALIDITY=9$1/s;
	ok(!lei('import', $u), 'UIDVALIDITY mismatch in URL rejected');

	lei_ok('inspect', $url);
	my $inspect = json_utf8->decode($lei_out);
	my @k = keys %$inspect;
	is(scalar(@k), 1, 'one URL resolved');
	is($k[0], $url, 'inspect URL matches');
	my $stats = $inspect->{$k[0]};
	is_deeply([ sort keys %$stats ],
		[ qw(uid.count uid.max uid.min) ], 'keys match');
	ok($stats->{'uid.min'} < $stats->{'uid.max'}, 'min < max');
	ok($stats->{'uid.count'} > 0, 'count > 0');

	lei_ok(qw(q z:1..));
	$out = json_utf8->decode($lei_out);
	ok(scalar(@$out) > 1, 'got imported messages');
	is(pop @$out, undef, 'trailing JSON null element was null');
	my %r;
	for (@$out) { $r{ref($_)}++ }
	is_deeply(\%r, { 'HASH' => scalar(@$out) }, 'all hashes');
	lei_ok([qw(tag +kw:seen), $url], undef, undef);

	my $f = "$ENV{HOME}/.local/share/lei/store/mail_sync.sqlite3";
	ok(-s $f, 'mail_sync tracked for redundant imports');
	lei_ok('inspect', "blob:$out->[5]->{blob}");
	my $x = json_utf8->decode($lei_out);
	is(ref($x->{'lei/store'}), 'ARRAY', 'lei/store in inspect');
	is(ref($x->{'mail-sync'}), 'HASH', 'sync in inspect');
	is(ref($x->{'mail-sync'}->{$k[0]}), 'ARRAY', 'UID arrays in inspect')
		or diag explain($x);

	my $psgi_attach = 'cfa3622cbeffc9bd6b0fc66c4d60d420ba74f60d';
	lei_ok('blob', $psgi_attach);
	like($lei_out, qr!^Content-Type: multipart/mixed;!sm, 'got full blob');
	lei_ok('blob', "$psgi_attach:2");
	is($lei_out, "b64\xde\xad\xbe\xef\n", 'got attachment');

	lei_ok 'forget-mail-sync', $url;
	lei_ok 'ls-mail-sync';
	unlike($lei_out, qr!\Q$host_port\E!, 'sync info gone after forget');
});
done_testing;
