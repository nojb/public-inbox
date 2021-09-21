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
	my $url = "nntp://$host_port/t.v2";
	lei_ok(qw(ls-mail-source), "nntp://$host_port/");
	like($lei_out, qr/^t\.v2$/ms, 'shows newsgroup');
	lei_ok(qw(ls-mail-source), $url);
	is($lei_out, "t.v2\n", 'shows only newsgroup with filter');
	lei_ok(qw(ls-mail-source -l), "nntp://$host_port/");
	is(ref(json_utf8->decode($lei_out)), 'ARRAY', 'ls-mail-source JSON');

	lei_ok('import', $url);
	lei_ok(qw(q z:1..));
	$out = json_utf8->decode($lei_out);
	ok(scalar(@$out) > 1, 'got imported messages');
	is(pop @$out, undef, 'trailing JSON null element was null');
	my %r;
	for (@$out) { $r{ref($_)}++ }
	is_deeply(\%r, { 'HASH' => scalar(@$out) }, 'all hashes');

	my $f = "$ENV{HOME}/.local/share/lei/store/mail_sync.sqlite3";
	ok(-s $f, 'mail_sync exists tracked for redundant imports');
	lei_ok 'ls-mail-sync';
	like($lei_out, qr!\A\Q$url\E\n\z!, 'ls-mail-sync output as-expected');

	ok(!lei(qw(import), "$url/12-1"), 'backwards range rejected');

	# new home
	local $ENV{HOME} = "$tmpdir/h2";
	lei_ok(qw(ls-mail-source -l), $url);
	my $ls = json_utf8->decode($lei_out);
	my ($high, $low) = @{$ls->[0]}{qw(high low)};
	ok($high > $low, 'high > low');

	my $end = $high - 1;
	lei_ok qw(import), "$url/$high";
	lei_ok('inspect', $url); is_xdeeply(json_utf8->decode($lei_out), {
		$url => { 'article.count' => 1,
			  'article.min' => $high,
			  'article.max' => $high, }
	}, 'inspect output for URL after single message') or diag $lei_out;
	lei_ok('inspect', "$url/$high");
	my $x = json_utf8->decode($lei_out);
	like($x->{$url}->{$high}, qr/\A[a-f0-9]{40,}\z/, 'inspect shows blob');

	lei_ok 'ls-mail-sync';
	is($lei_out, "$url\n", 'article number not stored as folder');
	lei_ok qw(q z:0..); my $one = json_utf8->decode($lei_out);
	pop @$one; # trailing null
	is(scalar(@$one), 1, 'only 1 result');

	local $ENV{HOME} = "$tmpdir/h3";
	lei_ok qw(import), "$url/$low-$end";
	lei_ok('inspect', $url); is_xdeeply(json_utf8->decode($lei_out), {
		$url => { 'article.count' => $end - $low + 1,
			  'article.min' => $low,
			  'article.max' => $end, }
	}, 'inspect output for URL after range') or diag $lei_out;
	lei_ok('inspect', "$url/$low-$end");
	$x = json_utf8->decode($lei_out);
	is_deeply([ ($low..$end) ], [ sort { $a <=> $b } keys %{$x->{$url}} ],
		'inspect range shows range');
	is(scalar(grep(/\A[a-f0-9]{40,}\z/, values %{$x->{$url}})),
		$end - $low + 1, 'all values are git blobs');

	lei_ok 'ls-mail-sync';
	is($lei_out, "$url\n", 'article range not stored as folder');
	lei_ok qw(q z:0..); my $start = json_utf8->decode($lei_out);
	pop @$start; # trailing null
	is(scalar(@$start), scalar(map { $_ } ($low..$end)),
		'range worked as expected');
	my %seen;
	for (@$start, @$one) {
		is($seen{$_->{blob}}++, 0, "blob $_->{blob} seen once");
	}
});
done_testing;
