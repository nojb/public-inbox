#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Spec;
require_mods(qw(lei));
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $env = { PI_CONFIG => $cfg_path };
my $srv = {};

SKIP: {
	require_mods(qw(-nntpd Net::NNTP), 1);
	my $rdr = { 3 => tcp_server };
	$srv->{nntpd} = start_script(
		[qw(-nntpd -W0), "--stdout=$tmpdir/n1", "--stderr=$tmpdir/n2"],
		$env, $rdr) or xbail "nntpd: $?";
	$srv->{nntp_host_port} = tcp_host_port($rdr->{3});
}

SKIP: {
	require_mods(qw(-imapd Mail::IMAPClient), 1);
	my $rdr = { 3 => tcp_server };
	$srv->{imapd} = start_script(
		[qw(-imapd -W0), "--stdout=$tmpdir/i1", "--stderr=$tmpdir/i2"],
		$env, $rdr) or xbail("-imapd $?");
	$srv->{imap_host_port} = tcp_host_port($rdr->{3});
}

for ('', qw(cur new)) {
	mkdir "$tmpdir/md/$_" or xbail "mkdir: $!";
	mkdir "$tmpdir/md1/$_" or xbail "mkdir: $!";
}
symlink(File::Spec->rel2abs('t/plack-qp.eml'), "$tmpdir/md/cur/x:2,");
my $expect = do {
	open my $fh, '<', 't/plack-qp.eml' or xbail $!;
	local $/;
	<$fh>;
};

# mbsync and offlineimap both put ":2," in "new/" files:
symlink(File::Spec->rel2abs('t/utf8.eml'), "$tmpdir/md/new/u:2,") or
	xbail "symlink $!";

symlink(File::Spec->rel2abs('t/mda-mime.eml'), "$tmpdir/md1/cur/x:2,S") or
	xbail "symlink $!";

test_lei({ tmpdir => $tmpdir }, sub {
	my $store_path = "$ENV{HOME}/.local/share/lei/store/";

	lei_ok('index', "$tmpdir/md");
	lei_ok(qw(q mid:qp@example.com));
	my $res_a = json_utf8->decode($lei_out);
	my $blob = $res_a->[0]->{'blob'};
	like($blob, qr/\A[0-9a-f]{40,}\z/, 'got blob from qp@example');
	lei_ok(qw(-C / blob), $blob);
	is($lei_out, $expect, 'got expected blob via Maildir');
	lei_ok(qw(q mid:qp@example.com -f text));
	like($lei_out, qr/^hi = bye/sm, 'lei2mail fallback');

	lei_ok(qw(q mid:testmessage@example.com -f text));
	lei_ok(qw(-C / blob --mail 9bf1002c49eb075df47247b74d69bcd555e23422));

	my $all_obj = ['git', "--git-dir=$store_path/ALL.git",
			qw(cat-file --batch-check --batch-all-objects)];
	is_deeply([xqx($all_obj)], [], 'no git objects');
	lei_ok('import', 't/plack-qp.eml');
	ok(grep(/\A$blob blob /, my @objs = xqx($all_obj)),
		'imported blob');
	lei_ok(qw(q m:qp@example.com --dedupe=none));
	my $res_b = json_utf8->decode($lei_out);
	is_deeply($res_b, $res_a, 'no extra DB entries');

	# ensure tag works on index-only messages:
	lei_ok(qw(tag +kw:seen t/utf8.eml));
	lei_ok(qw(q mid:testmessage@example.com));
	is_deeply(json_utf8->decode($lei_out)->[0]->{kw},
		['seen'], 'seen kw can be set on index-only message');

	lei_ok(qw(q z:0.. -o), "$tmpdir/all-results") for (1..2);
	is_deeply([xqx($all_obj)], \@objs,
		'no new objects after 2x q to trigger implicit import');

	lei_ok 'index', "$tmpdir/md1/cur/x:2,S";
	lei_ok qw(q m:multipart-html-sucks@11);
	is_deeply(json_utf8->decode($lei_out)->[0]->{'kw'},
		['seen'], 'keyword set');
	lei_ok 'reindex';
	lei_ok qw(q m:multipart-html-sucks@11);
	is_deeply(json_utf8->decode($lei_out)->[0]->{'kw'},
		['seen'], 'keyword still set after reindex');

	$srv->{nntpd} and
		lei_ok('index', "nntp://$srv->{nntp_host_port}/t.v2");
	$srv->{imapd} and
		lei_ok('index', "imap://$srv->{imap_host_port}/t.v2.0");
	is_deeply([xqx($all_obj)], \@objs, 'no new objects from NNTP+IMAP');

	lei_ok qw(q m:multipart-html-sucks@11);
	$res_a = json_utf8->decode($lei_out)->[0];
	is_deeply($res_a->{'kw'}, ['seen'],
		'keywords still set after NNTP + IMAP import');

	# ensure import works after lms->local_blob fallback in lei/store
	lei_ok('import', 't/mda-mime.eml');
	lei_ok qw(q m:multipart-html-sucks@11);
	$res_b = json_utf8->decode($lei_out)->[0];
	my $t = xqx(['git', "--git-dir=$store_path/ALL.git",
			qw(cat-file -t), $res_b->{blob}]);
	is($t, "blob\n", 'got blob');

	lei_ok('reindex');
	lei_ok qw(q m:multipart-html-sucks@11);
	$res_a = json_utf8->decode($lei_out)->[0];
	is_deeply($res_a->{'kw'}, ['seen'],
		'keywords still set after reindex');
});

done_testing;
