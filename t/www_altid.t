# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Inbox;
use PublicInbox::InboxWritable;
use PublicInbox::Config;
use PublicInbox::Spawn qw(which spawn);
which('sqlite3') or plan skip_all => 'sqlite3 binary missing';
require_mods(qw(DBD::SQLite HTTP::Request::Common Plack::Test URI::Escape
	Plack::Builder IO::Uncompress::Gunzip));
use_ok($_) for qw(Plack::Test HTTP::Request::Common);
require_ok 'PublicInbox::Msgmap';
require_ok 'PublicInbox::AltId';
require_ok 'PublicInbox::WWW';
my ($inboxdir, $for_destroy) = tmpdir();
my $aid = 'xyz';
my $spec = "serial:$aid:file=blah.sqlite3";
if ('setup') {
	my $opts = {
		inboxdir => $inboxdir,
		name => 'test',
		-primary_address => 'test@example.com',
	};
	my $ibx = PublicInbox::Inbox->new($opts);
	$ibx = PublicInbox::InboxWritable->new($ibx, 1);
	my $im = $ibx->importer(0);
	my $mime = PublicInbox::Eml->new(<<'EOF');
From: a@example.com
Message-Id: <a@example.com>

EOF
	$im->add($mime);
	$im->done;
	mkdir "$inboxdir/public-inbox" or die;
	my $altid = PublicInbox::AltId->new($ibx, $spec, 1);
	$altid->mm_alt->mid_set(1, 'a@example.com');
}

my $cfgpath = "$inboxdir/cfg";
open my $fh, '>', $cfgpath or die;
print $fh <<EOF or die;
[publicinbox "test"]
	inboxdir = $inboxdir
	address = test\@example.com
	altid = $spec
	url = http://example.com/test
EOF
close $fh or die;
my $cfg = PublicInbox::Config->new($cfgpath);
my $www = PublicInbox::WWW->new($cfg);
my $cmpfile = "$inboxdir/cmp.sqlite3";
my $client = sub {
	my ($cb) = @_;
	my $res = $cb->(POST("/test/$aid.sql.gz"));
	is($res->code, 200, 'retrieved gzipped dump');
	IO::Uncompress::Gunzip::gunzip(\($res->content) => \(my $buf));
	pipe(my ($r, $w)) or die;
	my $cmd = ['sqlite3', $cmpfile];
	my $pid = spawn($cmd, undef, { 0 => $r });
	print $w $buf or die;
	close $w or die;
	is(waitpid($pid, 0), $pid, 'sqlite3 exited');
	is($?, 0, 'sqlite3 loaded dump');
	my $mm_cmp = PublicInbox::Msgmap->new_file($cmpfile);
	is($mm_cmp->mid_for(1), 'a@example.com', 'sqlite3 dump valid');
	$mm_cmp = undef;
	unlink $cmpfile or die;
};
test_psgi(sub { $www->call(@_) }, $client);
SKIP: {
	require_mods(qw(Plack::Test::ExternalServer), 4);
	my $env = { PI_CONFIG => $cfgpath };
	my $sock = tcp_server() or die;
	my ($out, $err) = map { "$inboxdir/std$_.log" } qw(out err);
	my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
	my $td = start_script($cmd, $env, { 3 => $sock });
	my ($h, $p) = tcp_host_port($sock);
	local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = "http://$h:$p";
	Plack::Test::ExternalServer::test_psgi(client => $client);
}
done_testing;
