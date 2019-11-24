# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# manifest.js.gz generation and grok-pull integration test
use strict;
use warnings;
use Test::More;
use PublicInbox::Spawn qw(which);
require './t/common.perl';
my @mods = qw(URI::Escape Plack::Builder Digest::SHA
		IO::Compress::Gzip IO::Uncompress::Gunzip HTTP::Tiny);
foreach my $mod (@mods) {
	eval("require $mod") or plan skip_all => "$mod missing for $0";
}

require PublicInbox::WwwListing;
my $json = eval { PublicInbox::WwwListing::_json() };
plan skip_all => "JSON module missing: $@" if $@;

use_ok 'PublicInbox::Git';

my ($tmpdir, $for_destroy) = tmpdir();
my $bare = PublicInbox::Git->new("$tmpdir/bare.git");
is(system(qw(git init -q --bare), $bare->{git_dir}), 0, 'git init --bare');
is(PublicInbox::WwwListing::fingerprint($bare), undef,
	'empty repo has no fingerprint');
{
	my $fi_data = './t/git.fast-import-data';
	local $ENV{GIT_DIR} = $bare->{git_dir};
	is(system("git fast-import --quiet <$fi_data"), 0, 'fast-import');
}

like(PublicInbox::WwwListing::fingerprint($bare), qr/\A[a-f0-9]{40}\z/,
	'got fingerprint with non-empty repo');

sub tiny_test {
	my ($host, $port) = @_;
	my $http = HTTP::Tiny->new;
	my $res = $http->get("http://$host:$port/manifest.js.gz");
	is($res->{status}, 200, 'got manifest');
	my $tmp;
	IO::Uncompress::Gunzip::gunzip(\(delete $res->{content}) => \$tmp);
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
	is(HTTP::Date::time2str($bare->{modified}),
		$res->{headers}->{'last-modified'},
		'modified field and Last-Modified header match');

	ok(my $v2epoch0 = $manifest->{'/v2/git/0.git'}, 'v2 epoch 0 appeared');
	like($v2epoch0->{description}, qr/ \[epoch 0\]\z/,
		'epoch 0 in description');
	ok(my $v2epoch1 = $manifest->{'/v2/git/1.git'}, 'v2 epoch 1 appeared');
	like($v2epoch1->{description}, qr/ \[epoch 1\]\z/,
		'epoch 1 in description');
}

my $td;
SKIP: {
	my $err = "$tmpdir/stderr.log";
	my $out = "$tmpdir/stdout.log";
	my $alt = "$tmpdir/alt.git";
	my $cfgfile = "$tmpdir/config";
	my $v2 = "$tmpdir/v2";
	my $sock = tcp_server();
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

	close $fh or die;
	my $env = { PI_CONFIG => $cfgfile };
	my $cmd = [ '-httpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	$td = start_script($cmd, $env, { 3 => $sock });
	$sock = undef;

	tiny_test($host, $port);

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
