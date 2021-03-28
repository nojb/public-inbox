#!perl -w
# Copyright (C) 2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
require_git 2.6;
require_mods(qw(-imapd Search::Xapian Mail::IMAPClient));
use PublicInbox::Config;
my ($tmpdir, $for_destroy) = tmpdir;
my ($ro_home, $cfg_path) = setup_public_inboxes;
my $cmd = [ '-imapd', '-W0', "--stdout=$tmpdir/1", "--stderr=$tmpdir/2" ];
my $sock = tcp_server;
my $env = { PI_CONFIG => $cfg_path };
my $td = start_script($cmd, $env, { 3 => $sock }) or BAIL_OUT "-imapd: $?";
my ($host, $port) = tcp_host_port $sock;
require_ok 'PublicInbox::NetReader';
my $nrd = PublicInbox::NetReader->new;
$nrd->add_url(my $url = "imap://$host:$port/t.v2.0");
is($nrd->errors, undef, 'no errors');
$nrd->{pi_cfg} = PublicInbox::Config->new($cfg_path);
$nrd->imap_common_init;
$nrd->{quiet} = 1;
my (%eml, %urls, %args, $nr, @w);
local $SIG{__WARN__} = sub { push(@w, @_) };
$nrd->imap_each($url, sub {
	my ($u, $uid, $kw, $eml, $arg) = @_;
	++$urls{$u};
	++$args{$arg};
	like($uid, qr/\A[0-9]+\z/, 'got digit UID '.$uid);
	++$eml{ref($eml)};
	++$nr;
}, 'blah');
is(scalar(@w), 0, 'no warnings');
ok($nr, 'got some emails');
is($eml{'PublicInbox::Eml'}, $nr, 'got expected Eml objects');
is(scalar keys %eml, 1, 'only got Eml objects');
is($urls{$url}, $nr, 'one URL expected number of times');
is(scalar keys %urls, 1, 'only got one URL');
is($args{blah}, $nr, 'got arg expected number of times');
is(scalar keys %args, 1, 'only got one arg');

done_testing;
