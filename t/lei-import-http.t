#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Spawn qw(which);
require_mods(qw(lei -httpd));
which('curl') or plan skip_all => "curl required for $0";
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $sock = tcp_server;
my $cmd = [ '-httpd', '-W0', "--stdout=$tmpdir/1", "--stderr=$tmpdir/2" ];
my $env = { PI_CONFIG => $cfg_path };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-httpd $?");
my $host_port = tcp_host_port($sock);
undef $sock;
test_lei({ tmpdir => $tmpdir }, sub {
	my $url = "http://$host_port/t2";
	for my $p (qw(bogus@x/t.mbox.gz bogus@x/raw ?q=noresultever)) {
		ok(!lei('import', "$url/$p"), "/$p fails properly");
	}
	for my $p (qw(/ /T/ /t/ /t.atom)) {
		ok(!lei('import', "$url/m\@example$p"), "/$p fails");
		like($lei_err, qr/did you mean/, "gave hint for $p");
	}
	lei_ok 'import', "$url/testmessage\@example.com/raw";
	lei_ok 'q', 'm:testmessage@example.com';
	my $res = json_utf8->decode($lei_out);
	is($res->[0]->{'m'}, 'testmessage@example.com', 'imported raw')
		or diag explain($res);

	lei_ok 'import', "$url/qp\@example.com/t.mbox.gz";
	lei_ok 'q', 'm:qp@example.com';
	$res = json_utf8->decode($lei_out);
	is($res->[0]->{'m'}, 'qp@example.com', 'imported t.mbox.gz')
		or diag explain($res);

	lei_ok 'import', "$url/?q=s:boolean";
	lei_ok 'q', 'm:20180720072141.GA15957@example';
	$res = json_utf8->decode($lei_out);
	is($res->[0]->{'m'}, '20180720072141.GA15957@example',
			'imported search result') or diag explain($res);

	ok(!lei(qw(import --mail-sync), "$url/x\@example.com/raw"),
		'--mail-sync fails on HTTP');
});
done_testing;
