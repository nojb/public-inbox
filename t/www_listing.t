#!perl -w
# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# manifest.js.gz generation and grok-pull integration test
use strict; use v5.10.1; use PublicInbox::TestCommon;
use PublicInbox::Import;
use IO::Uncompress::Gunzip qw(gunzip);
require_mods(qw(json URI::Escape Plack::Builder Digest::SHA HTTP::Tiny));
require PublicInbox::WwwListing;
require PublicInbox::ManifestJsGz;
use PublicInbox::Config;
my $json = PublicInbox::Config::json();

use_ok 'PublicInbox::Git';

my ($tmpdir, $for_destroy) = tmpdir();
my $bare = PublicInbox::Git->new("$tmpdir/bare.git");
PublicInbox::Import::init_bare($bare->{git_dir});
is($bare->manifest_entry, undef, 'empty repo has no manifest entry');
{
	my $fi_data = './t/git.fast-import-data';
	open my $fh, '<', $fi_data or die "open $fi_data: $!";
	my $env = { GIT_DIR => $bare->{git_dir} };
	is(xsys([qw(git fast-import --quiet)], $env, { 0 => $fh }), 0,
		'fast-import');
}

like($bare->manifest_entry->{fingerprint}, qr/\A[a-f0-9]{40}\z/,
	'got fingerprint with non-empty repo');

sub tiny_test {
	my ($json, $host, $port, $html) = @_;
	my ($tmp, $res);
	my $http = HTTP::Tiny->new;
	if ($html) {
		$res = $http->get("http://$host:$port/");
		is($res->{status}, 200, 'got HTML listing');
		like($res->{content}, qr!</html>!si, 'listing looks like HTML');

		$res = $http->get("http://$host:$port/",
				{'Accept-Encoding'=>'gzip'});
		is($res->{status}, 200, 'got gzipped HTML listing');
		gunzip(\(delete $res->{content}) => \$tmp);
		like($tmp, qr!</html>!si, 'unzipped listing looks like HTML');
	}
	$res = $http->get("http://$host:$port/manifest.js.gz");
	is($res->{status}, 200, 'got manifest');
	gunzip(\(delete $res->{content}) => \$tmp);
	unlike($tmp, qr/"modified":\s*"/, 'modified is an integer');
	my $manifest = $json->decode($tmp);
	ok(my $clone = $manifest->{'/alt'}, '/alt in manifest');
	is($clone->{owner}, "lorelei \x{100}", 'owner set');
	is($clone->{reference}, '/bare', 'reference detected');
	is($clone->{description}, "we're \x{100}ll clones", 'description read');
	ok(my $bare = $manifest->{'/bare'}, '/bare in manifest');
	is($bare->{description}, 'Unnamed repository',
		'missing $GIT_DIR/description fallback');

	like($bare->{fingerprint}, qr/\A[a-f0-9]{40}\z/, 'fingerprint');
	is($clone->{fingerprint}, $bare->{fingerprint}, 'fingerprint matches');
	is(HTTP::Date::time2str($bare->{modified}),
		$res->{headers}->{'last-modified'},
		'modified field and Last-Modified header match');

	ok(my $v2epoch0 = $manifest->{'/v2/git/0.git'}, 'v2 epoch 0 appeared');
	like($v2epoch0->{description}, qr/ \[epoch 0\]\z/,
		'epoch 0 in description');
	ok(my $v2epoch1 = $manifest->{'/v2/git/1.git'}, 'v2 epoch 1 appeared');
	like($v2epoch1->{description}, qr/ \[epoch 1\]\z/,
		'epoch 1 in description');

	$res = $http->get("http://$host:$port/alt/description");
	is($res->{content}, "we're \xc4\x80ll clones\n", 'UTF-8 description')
		or diag explain($res);
}

my $td;
SKIP: {
	my $err = "$tmpdir/stderr.log";
	my $out = "$tmpdir/stdout.log";
	my $alt = "$tmpdir/alt.git";
	my $cfgfile = "$tmpdir/config";
	my $v2 = "$tmpdir/v2";
	my $sock = tcp_server();
	my ($host, $port) = tcp_host_port($sock);
	my @clone = qw(git clone -q -s --bare);
	is(xsys(@clone, $bare->{git_dir}, $alt), 0, 'clone shared repo');

	PublicInbox::Import::init_bare("$v2/all.git");
	for my $i (0..2) {
		is(xsys(@clone, $alt, "$v2/git/$i.git"), 0, "clone epoch $i")
	}
	ok(open(my $fh, '>', "$v2/inbox.lock"), 'mock a v2 inbox');
	open $fh, '>', "$alt/description" or xbail "open $alt/description $!";
	print $fh "we're \xc4\x80ll clones\n" or xbail "print $!";
	close $fh or xbail "write: $alt/description $!";
	is(xsys('git', "--git-dir=$alt", qw(config gitweb.owner),
		"lorelei \xc4\x80"), 0,
		'set gitweb user');
	open $fh, '>', $cfgfile or xbail "open $cfgfile: $!";
	$fh->autoflush(1);
	print $fh <<"" or xbail "print $!";
[publicinbox "bare"]
	inboxdir = $bare->{git_dir}
	url = http://$host/bare
	address = bare\@example.com
[publicinbox "alt"]
	inboxdir = $alt
	url = http://$host/alt
	address = alt\@example.com
[publicinbox "v2"]
	inboxdir = $v2
	url = http://$host/v2
	address = v2\@example.com

	my $env = { PI_CONFIG => $cfgfile };
	my $cmd = [ '-httpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, $env, { 3 => $sock });

	# default publicinboxGrokManifest match=domain default
	tiny_test($json, $host, $port);
	undef $td;

	print $fh <<"" or xbail "print $!";
[publicinbox]
	wwwlisting = all

	close $fh or xbail "close $!";
	$td = start_script($cmd, $env, { 3 => $sock });
	tiny_test($json, $host, $port, 1);
	undef $sock;

	skip 'TEST_GROK unset', 12 unless $ENV{TEST_GROK};
	my $grok_pull = require_cmd('grok-pull', 1) or
		skip('grok-pull not available', 12);
	my ($grok_version) = (xqx([$grok_pull, "--version"])
			=~ /(\d+)\.(?:\d+)(?:\.(\d+))?/);
	$grok_version >= 2 or
		skip('grok-pull v2 or later not available', 12);
	my $grok_loglevel = $ENV{TEST_GROK_LOGLEVEL} // 'info';

	ok(mkdir("$tmpdir/mirror"), 'prepare grok mirror dest');
	my $tail = tail_f("$tmpdir/grok.log");
	open $fh, '>', "$tmpdir/repos.conf" or xbail $!;
	print $fh <<"" or xbail $!;
[core]
toplevel = $tmpdir/mirror
manifest = $tmpdir/local-manifest.js.gz
log = $tmpdir/grok.log
loglevel = $grok_loglevel
[remote]
site = http://$host:$port
manifest = \${site}/manifest.js.gz
[pull]
[fsck]

	close $fh or xbail $!;
	xsys($grok_pull, '-c', "$tmpdir/repos.conf");
	is($? >> 8, 0, 'grok-pull exit code as expected');
	for (qw(alt bare v2/git/0.git v2/git/1.git v2/git/2.git)) {
		ok(-d "$tmpdir/mirror/$_", "grok-pull created $_");
	}

	# support per-inbox manifests, handy for v2:
	# /$INBOX/v2/manifest.js.gz
	open $fh, '>', "$tmpdir/per-inbox.conf" or xbail $!;
	print $fh <<"" or xbail $!;
[core]
toplevel = $tmpdir/per-inbox
manifest = $tmpdir/per-inbox-manifest.js.gz
log = $tmpdir/grok.log
loglevel = $grok_loglevel
[remote]
site = http://$host:$port
manifest = \${site}/v2/manifest.js.gz
[pull]
[fsck]

	close $fh or xbail $!;
	ok(mkdir("$tmpdir/per-inbox"), 'prepare single-v2-inbox mirror');
	xsys($grok_pull, '-c', "$tmpdir/per-inbox.conf");
	is($? >> 8, 0, 'grok-pull exit code as expected');
	for (qw(v2/git/0.git v2/git/1.git v2/git/2.git)) {
		ok(-d "$tmpdir/per-inbox/$_", "grok-pull created $_");
	}
	$td->kill;
	$td->join;
	is($?, 0, 'no error in exited process');
	open $fh, '<', $err or BAIL_OUT("open $err failed: $!");
	my $eout = do { local $/; <$fh> };
	unlike($eout, qr/wide/i, 'no Wide character warnings');
	unlike($eout, qr/uninitialized/i, 'no uninitialized warnings');
}

done_testing();
