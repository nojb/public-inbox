#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Spec;
require_mods(qw(lei -nntpd));
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $env = { PI_CONFIG => $cfg_path };

my $sock = tcp_server;
my $cmd = [ '-nntpd', '-W0', "--stdout=$tmpdir/n1", "--stderr=$tmpdir/n2" ];
my $nntpd = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-nntpd $?");
my $nntp_host_port = tcp_host_port($sock);

$sock = tcp_server;
$cmd = [ '-imapd', '-W0', "--stdout=$tmpdir/i1", "--stderr=$tmpdir/i2" ];
my $imapd = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-imapd $?");
my $imap_host_port = tcp_host_port($sock);
undef $sock;
for ('', qw(cur new)) {
	mkdir "$tmpdir/md/$_" or xbail "mkdir: $!";
}
symlink(File::Spec->rel2abs('t/plack-qp.eml'), "$tmpdir/md/cur/x:2,");
my $expect = do {
	open my $fh, '<', 't/plack-qp.eml' or xbail $!;
	local $/;
	<$fh>;
};
test_lei({ tmpdir => $tmpdir }, sub {
	my $store_path = "$ENV{HOME}/.local/share/lei/store/";

	lei_ok('index', "$tmpdir/md");
	lei_ok(qw(q mid:qp@example.com));
	my $res_a = json_utf8->decode($lei_out);
	my $blob = $res_a->[0]->{'blob'};
	like($blob, qr/\A[0-9a-f]{40,}\z/, 'got blob from qp@example');
	lei_ok('blob', $blob);
	is($lei_out, $expect, 'got expected blob via Maildir');
	lei_ok(qw(q mid:qp@example.com -f text));
	like($lei_out, qr/^hi = bye/sm, 'lei2mail fallback');

	my $all_obj = ['git', "--git-dir=$store_path/ALL.git",
			qw(cat-file --batch-check --batch-all-objects)];
	is_deeply([xqx($all_obj)], [], 'no git objects');
	lei_ok('import', 't/plack-qp.eml');
	ok(grep(/\A$blob blob /, my @objs = xqx($all_obj)),
		'imported blob');
	lei_ok(qw(q z:0.. --dedupe=none));
	my $res_b = json_utf8->decode($lei_out);
	is_deeply($res_b, $res_a, 'no extra DB entries');

	lei_ok('index', "nntp://$nntp_host_port/t.v2");
	lei_ok('index', "imap://$imap_host_port/t.v2.0");
	is_deeply([xqx($all_obj)], \@objs, 'no new objects from NNTP+IMAP');
});

done_testing;
