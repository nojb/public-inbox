#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use PublicInbox::Spawn qw(which spawn);
which('sqlite3') or plan skip_all => 'sqlite3 binary missing';
require_mods(qw(DBD::SQLite HTTP::Request::Common Plack::Test URI::Escape
	Plack::Builder IO::Uncompress::Gunzip));
use_ok($_) for qw(Plack::Test HTTP::Request::Common);
require_ok 'PublicInbox::Msgmap';
require_ok 'PublicInbox::AltId';
require_ok 'PublicInbox::WWW';
my ($tmpdir, $for_destroy) = tmpdir();
my $aid = 'xyz';
my $cfgpath;
my $ibx = create_inbox 'test', indexlevel => 'basic', sub {
	my ($im, $ibx) = @_;
	$im->add(PublicInbox::Eml->new(<<'EOF')) or BAIL_OUT;
From: a@example.com
Message-Id: <a@example.com>

EOF
	# $im->done;
	my $spec = "serial:$aid:file=blah.sqlite3";
	my $altid = PublicInbox::AltId->new($ibx, $spec, 1);
	$altid->mm_alt->mid_set(1, 'a@example.com');
	$cfgpath = "$ibx->{inboxdir}/cfg";
	open my $fh, '>', $cfgpath or BAIL_OUT "open $cfgpath: $!";
	print $fh <<EOF or BAIL_OUT $!;
[publicinbox "test"]
	inboxdir = $ibx->{inboxdir}
	address = $ibx->{-primary_address}
	altid = $spec
	url = http://example.com/test
EOF
	close $fh or BAIL_OUT $!;
};
$cfgpath //= "$ibx->{inboxdir}/cfg";
my $cfg = PublicInbox::Config->new($cfgpath);
my $www = PublicInbox::WWW->new($cfg);
my $cmpfile = "$tmpdir/cmp.sqlite3";
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
	my ($out, $err) = map { "$tmpdir/std$_.log" } qw(out err);
	my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
	my $td = start_script($cmd, $env, { 3 => $sock });
	my ($h, $p) = tcp_host_port($sock);
	local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = "http://$h:$p";
	Plack::Test::ExternalServer::test_psgi(client => $client);
}
done_testing;
