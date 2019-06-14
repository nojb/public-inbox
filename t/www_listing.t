# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# manifest.js.gz generation and grok-pull integration test
use strict;
use warnings;
use Test::More;
use PublicInbox::Spawn qw(which);
use File::Temp qw/tempdir/;
require './t/common.perl';
my @mods = qw(URI::Escape Plack::Builder IPC::Run Digest::SHA HTTP::Tiny
		IO::Compress::Gzip IO::Uncompress::Gunzip Net::HTTP);
foreach my $mod (@mods) {
	eval("require $mod") or plan skip_all => "$mod missing for $0";
}
use_ok 'PublicInbox::WwwListing';
use_ok 'PublicInbox::Git';

my $fi_data = './t/git.fast-import-data';
my $tmpdir = tempdir('www_listing-tmp-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $bare = PublicInbox::Git->new("$tmpdir/bare.git");
is(system(qw(git init -q --bare), $bare->{git_dir}), 0, 'git init --bare');
is(PublicInbox::WwwListing::fingerprint($bare), undef,
	'empty repo has no fingerprint');

my $cmd = [ 'git', "--git-dir=$bare->{git_dir}", qw(fast-import --quiet) ];
ok(IPC::Run::run($cmd, '<', $fi_data), 'fast-import');

like(PublicInbox::WwwListing::fingerprint($bare), qr/\A[a-f0-9]{40}\z/,
	'got fingerprint with non-empty repo');

my $pid;
END { kill 'TERM', $pid if defined $pid };
SKIP: {
	my $json = eval { PublicInbox::WwwListing::_json() };
	skip "JSON module missing: $@", 1 if $@;
	my $err = "$tmpdir/stderr.log";
	my $out = "$tmpdir/stdout.log";
	my $alt = "$tmpdir/alt.git";
	my $cfgfile = "$tmpdir/config";
	my $v2 = "$tmpdir/v2";
	my $httpd = 'blib/script/public-inbox-httpd';
	use IO::Socket::INET;
	my %opts = (
		LocalAddr => '127.0.0.1',
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => SOCK_STREAM,
		Listen => 1024,
	);
	my $sock = IO::Socket::INET->new(%opts);
	ok($sock, 'sock created');
	my ($host, $port) = ($sock->sockhost, $sock->sockport);
	my @clone = qw(git clone -q -s --bare);
	is(system(@clone, $bare->{git_dir}, $alt), 0, 'clone shared repo');

	for my $i (0..2) {
		is(system(@clone, $alt, "$v2/git/$i.git"), 0, "clone epoch $i");
	}
	ok(open(my $fh, '>', "$v2/inbox.lock"), 'mock a v2 inbox');
	open $fh, '>', "$alt/description" or die;
	print $fh "we're all clones\n" or die;
	close $fh or die;
	is(system('git', "--git-dir=$alt", qw(config gitweb.owner lorelei)), 0,
		'set gitweb user');
	ok(unlink("$bare->{git_dir}/description"), 'removed bare/description');
	open $fh, '>', $cfgfile or die;
	print $fh <<"" or die;
[publicinbox "bare"]
	mainrepo = $bare->{git_dir}
	url = http://$host/bare
	address = bare\@example.com
[publicinbox "alt"]
	mainrepo = $alt
	url = http://$host/alt
	address = alt\@example.com
[publicinbox "v2"]
	mainrepo = $v2
	url = http://$host/v2
	address = v2\@example.com

	close $fh or die;
	my $env = { PI_CONFIG => $cfgfile };
	my $cmd = [ $httpd, "--stdout=$out", "--stderr=$err" ];
	$pid = spawn_listener($env, $cmd, [$sock]);
	$sock = undef;
	my $http = Net::HTTP->new(Host => "$host:$port");
	$http->write_request(GET => '/manifest.js.gz');
	my ($code, undef, %h) = $http->read_response_headers;
	is($code, 200, 'got manifest');
	my $tmp;
	my $body = '';
	while (1) {
		my $n = $http->read_entity_body(my $buf, 65536);
		die unless defined $n;
		last if $n == 0;
		$body .= $buf;
	}
	IO::Uncompress::Gunzip::gunzip(\$body => \$tmp);
	unlike($tmp, qr/"modified":\s*"/, 'modified is an integer');
	my $manifest = $json->decode($tmp);
	ok(my $clone = $manifest->{'/alt'}, '/alt in manifest');
	is($clone->{owner}, 'lorelei', 'owner set');
	is($clone->{reference}, '/bare', 'reference detected');
	is($clone->{description}, "we're all clones", 'description read');
	ok(my $bare = $manifest->{'/bare'}, '/bare in manifest');
	is($bare->{description}, 'Unnamed repository',
		'missing $GIT_DIR/description fallback');

	like($bare->{fingerprint}, qr/\A[a-f0-9]{40}\z/, 'fingerprint');
	is($clone->{fingerprint}, $bare->{fingerprint}, 'fingerprint matches');

	is(HTTP::Date::time2str($bare->{modified}), $h{'Last-Modified'},
		'modified field and Last-Modified header match');

	ok($manifest->{'/v2/git/0.git'}, 'v2 epoch appeared');

	skip 'skipping grok-pull integration test', 2 if !which('grok-pull');

	ok(mkdir("$tmpdir/mirror"), 'prepare grok mirror dest');
	open $fh, '>', "$tmpdir/repos.conf" or die;
	print $fh <<"" or die;
# You can pull from multiple grok mirrors, just create
# a separate section for each mirror. The name can be anything.
[test]
site = http://$host:$port
manifest = http://$host:$port/manifest.js.gz
toplevel = $tmpdir/mirror
mymanifest = $tmpdir/local-manifest.js.gz

	close $fh or die;

	system(qw(grok-pull -c), "$tmpdir/repos.conf");
	is($? >> 8, 127, 'grok-pull exit code as expected');
	for (qw(alt bare v2/git/0.git v2/git/1.git v2/git/2.git)) {
		ok(-d "$tmpdir/mirror/$_", "grok-pull created $_");
	}

	# support per-inbox manifests, handy for v2:
	# /$INBOX/v2/manifest.js.gz
	open $fh, '>', "$tmpdir/per-inbox.conf" or die;
	print $fh <<"" or die;
# You can pull from multiple grok mirrors, just create
# a separate section for each mirror. The name can be anything.
[v2]
site = http://$host:$port
manifest = http://$host:$port/v2/manifest.js.gz
toplevel = $tmpdir/per-inbox
mymanifest = $tmpdir/per-inbox-manifest.js.gz

	close $fh or die;
	ok(mkdir("$tmpdir/per-inbox"), 'prepare single-v2-inbox mirror');
	system(qw(grok-pull -c), "$tmpdir/per-inbox.conf");
	is($? >> 8, 127, 'grok-pull exit code as expected');
	for (qw(v2/git/0.git v2/git/1.git v2/git/2.git)) {
		ok(-d "$tmpdir/per-inbox/$_", "grok-pull created $_");
	}
}

done_testing();
