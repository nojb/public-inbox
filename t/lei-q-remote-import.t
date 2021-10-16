#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_mods(qw(lei -httpd));
require_cmd 'curl';
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
	ok(-f $o && -s _, 'output exists after import but is not empty') or
		diag $lei_err;
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
	unlink $o or xbail("unlink $o $! cwd=".Cwd::getcwd());
	lei_ok(@cmd, '--lock=none');
	ok(-f $o && -s _, '--lock=none respected') or diag $lei_err;
	unlink $o or xbail("unlink $o $! cwd=".Cwd::getcwd());
	ok(!lei(@cmd, '--lock=dotlock,timeout=0.000001'), 'dotlock fails');
	like($lei_err, qr/dotlock timeout/, 'timeout noted');
	ok(-f $o && !-s _, 'nothing output on lock failure');
	unlink "$o.lock" or BAIL_OUT $!;
	lei_ok(@cmd, '--lock=dotlock,timeout=0.000001',
		\'succeeds after lock removal');

	my $ibx = create_inbox 'local-external', indexlevel => 'medium', sub {
		my ($im) = @_;
		$im->add(eml_load('t/utf8.eml')) or BAIL_OUT '->add';
	};
	lei_ok(qw(add-external -q), $ibx->{inboxdir});
	lei_ok(qw(q -q -o), "mboxrd:$o", '--only', $url,
		'm:testmessage@example.com');
	is($lei_err, '', 'no warnings or errors');
	ok(-s $o, 'got result from remote external');
	my $exp = eml_load('t/utf8.eml');
	is_deeply($slurp_emls->($o), [$exp], 'got expected result');
	lei_ok(qw(q --no-external -o), "mboxrd:/dev/stdout",
			'm:testmessage@example.com');
	is($lei_out, '', 'message not imported when in local external');

	open $fh, '>', $o or BAIL_OUT;
	print $fh <<'EOF' or BAIL_OUT;
From a@z Mon Sep 17 00:00:00 2001
From: nobody@localhost
Date: Sat, 13 Mar 2021 18:23:01 +0600
Message-ID: <never-before-seen@example.com>
Status: OR

whatever
EOF
	close $fh or BAIL_OUT;
	lei_ok(qw(q -o), "mboxrd:$o", 'm:testmessage@example.com');
	is_deeply($slurp_emls->($o), [$exp],
		'got expected result after clobber') or diag $lei_err;
	lei_ok(qw(q -o mboxrd:/dev/stdout m:never-before-seen@example.com));
	like($lei_out, qr/seen\@example\.com>\nStatus: RO\n\nwhatever/sm,
		'--import-before imported totally unseen message');

	lei_ok(qw(q --save z:0.. -o), "$ENV{HOME}/md", '--only', $url);
	my @f = glob("$ENV{HOME}/md/*/*");
	lei_ok('up', "$ENV{HOME}/md");
	is_deeply(\@f, [ glob("$ENV{HOME}/md/*/*") ],
		'lei up remote dedupe works on maildir');
	my $edit_env = { VISUAL => 'cat', EDITOR => 'cat' };
	lei_ok([qw(edit-search), "$ENV{HOME}/md"], $edit_env);
	like($lei_out, qr/^\Q[external "$url"]\E\n\s*lastresult = \d+/sm,
		'lastresult set');
});
done_testing;
