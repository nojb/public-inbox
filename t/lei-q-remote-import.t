#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(json DBD::SQLite Search::Xapian));
use PublicInbox::MboxReader;
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $sock = tcp_server;
my ($tmpdir, $for_destroy) = tmpdir;
my $cmd = [ '-httpd', '-W0', "--stdout=$tmpdir/1", "--stderr=$tmpdir/2" ];
my $env = { PI_CONFIG => $cfg_path };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT("-httpd: $?");
my $host_port = tcp_host_port($sock);
my $url = "http://$host_port/t2/";
my $exp1 = [ eml_load('t/plack-qp.eml') ];
my $exp2 = [ eml_load('t/iso-2202-jp.eml') ];
my $slurp_emls = sub {
	open my $fh, '<', $_[0] or BAIL_OUT "open: $!";
	my @eml;
	PublicInbox::MboxReader->mboxrd($fh, sub {
		my $eml = shift;
		$eml->header_set('Status');
		push @eml, $eml;
	});
	\@eml;
};

test_lei({ tmpdir => $tmpdir }, sub {
	my $o = "$ENV{HOME}/o.mboxrd";
	my @cmd = ('q', '-o', "mboxrd:$o", 'm:qp@example.com');
	lei_ok(@cmd);
	ok(-f $o && !-s _, 'output exists but is empty');
	unlink $o or BAIL_OUT $!;
	lei_ok(@cmd, '-I', $url);
	is_deeply($slurp_emls->($o), $exp1, 'got results after remote search');
	unlink $o or BAIL_OUT $!;
	lei_ok(@cmd);
	ok(-f $o && -s _, 'output exists after import but is not empty');
	is_deeply($slurp_emls->($o), $exp1, 'got results w/o remote search');
	unlink $o or BAIL_OUT $!;

	$cmd[-1] = 'm:199707281508.AAA24167@hoyogw.example';
	lei_ok(@cmd, '-I', $url, '--no-import-remote');
	is_deeply($slurp_emls->($o), $exp2, 'got another after remote search');
	unlink $o or BAIL_OUT $!;
	lei_ok(@cmd);
	ok(-f $o && !-s _, '--no-import-remote did not memoize');

	open my $fh, '>', "$o.lock";
	$cmd[-1] = 'm:qp@example.com';
	unlink $o or BAIL_OUT $!;
	lei_ok(@cmd, '--lock=none');
	ok(-f $o && -s _, '--lock=none respected');
	unlink $o or BAIL_OUT $!;
	ok(!lei(@cmd, '--lock=dotlock,timeout=0.000001'), 'dotlock fails');
	ok(-f $o && !-s _, 'nothing output on lock failure');
	unlink "$o.lock" or BAIL_OUT $!;
	lei_ok(@cmd, '--lock=dotlock,timeout=0.000001',
		\'succeeds after lock removal');
});
done_testing;
