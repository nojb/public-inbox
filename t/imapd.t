#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use Time::HiRes ();
use PublicInbox::TestCommon;
use PublicInbox::Config;
use PublicInbox::Spawn qw(which);
require_mods(qw(DBD::SQLite Mail::IMAPClient));

my $level = '-Lbasic';
SKIP: {
	require_mods('Search::Xapian', 1);
	$level = '-Lmedium';
};

my @V = (1);
push(@V, 2) if require_git('2.6', 1);

my ($tmpdir, $for_destroy) = tmpdir();
my $home = "$tmpdir/home";
local $ENV{HOME} = $home;

for my $V (@V) {
	my $addr = "i$V\@example.com";
	my $name = "i$V";
	my $url = "http://example.com/i$V";
	my $inboxdir = "$tmpdir/$name";
	my $folder = "inbox.i$V";
	my $cmd = ['-init', "-V$V", $level, $name, $inboxdir, $url, $addr];
	run_script($cmd) or BAIL_OUT("init $name");
	xsys(qw(git config), "--file=$ENV{HOME}/.public-inbox/config",
			"publicinbox.$name.newsgroup", $folder) == 0 or
			BAIL_OUT("setting newsgroup $V");
	if ($V == 1) {
		xsys(qw(git config), "--file=$ENV{HOME}/.public-inbox/config",
			'publicinboxmda.spamcheck', 'none') == 0 or
			BAIL_OUT("config: $?");
	}
	open(my $fh, '<', 't/utf8.eml') or BAIL_OUT("open t/utf8.eml: $!");
	my $env = { ORIGINAL_RECIPIENT => $addr };
	run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or
		BAIL_OUT('-mda delivery');
	if ($V == 1) {
		run_script(['-index', $inboxdir]) or BAIL_OUT("index $?");
	}
}
my $sock = tcp_server();
my $err = "$tmpdir/stderr.log";
my $out = "$tmpdir/stdout.log";
my $cmd = [ '-imapd', '-W0', "--stdout=$out", "--stderr=$err" ];
my $td = start_script($cmd, undef, { 3 => $sock }) or BAIL_OUT("-imapd: $?");
my %mic_opt = (
	Server => $sock->sockhost,
	Port => $sock->sockport,
	Uid => 1,
);
my $mic = Mail::IMAPClient->new(%mic_opt);
my $pre_login_capa = $mic->capability;
is(grep(/\AAUTH=ANONYMOUS\z/, @$pre_login_capa), 1,
	'AUTH=ANONYMOUS advertised pre-login');

$mic->User('lorelei');
$mic->Password('Hunter2');
ok($mic->login && $mic->IsAuthenticated, 'LOGIN works');
my $post_login_capa = $mic->capability;
ok(join("\n", @$pre_login_capa) ne join("\n", @$post_login_capa),
	'got different capabilities post-login');

$mic_opt{Authmechanism} = 'ANONYMOUS';
$mic_opt{Authcallback} = sub { '' };
$mic = Mail::IMAPClient->new(%mic_opt);
ok($mic && $mic->login && $mic->IsAuthenticated, 'AUTHENTICATE ANONYMOUS');
my $post_auth_anon_capa = $mic->capability;
is_deeply($post_auth_anon_capa, $post_login_capa,
	'auth anon has same capabilities');
my $e;
ok(!$mic->examine('foo') && ($e = $@), 'EXAMINE non-existent');
like($e, qr/\bNO\b/, 'got a NO on EXAMINE for non-existent');
ok(!$mic->select('foo') && ($e = $@), 'EXAMINE non-existent');
like($e, qr/\bNO\b/, 'got a NO on EXAMINE for non-existent');
ok($mic->select('inbox.i1'), 'SELECT succeeds');
ok($mic->examine('inbox.i1'), 'EXAMINE succeeds');
my @raw = $mic->status('inbox.i1', qw(Messages uidnext uidvalidity));
is(scalar(@raw), 2, 'got status response');
like($raw[0], qr/\A\*\x20STATUS\x20inbox\.i1\x20
	\(MESSAGES\x20\d+\x20UIDNEXT\x20\d+\x20UIDVALIDITY\x20\d+\)\r\n/sx);
like($raw[1], qr/\A\S+ OK /, 'finished status response');

@raw = $mic->list;
like($raw[0], qr/^\* LIST \(.*?\) "\." inbox/,
	'got an inbox');
like($raw[-1], qr/^\S+ OK /, 'response ended with OK');
is(scalar(@raw), scalar(@V) + 2, 'default LIST response');
@raw = $mic->list('', 'inbox.i1');
is(scalar(@raw), 2, 'limited LIST response');
like($raw[0], qr/^\* LIST \(.*?\) "\." inbox/,
		'got an inbox.i1');
like($raw[-1], qr/^\S+ OK /, 'response ended with OK');

{ # make sure we get '%' globbing right
	my @n = map { { newsgroup => $_ } } (qw(x.y.z x.z.y));
	my $self = { imapd => { grouplist => \@n } };
	PublicInbox::IMAPD::refresh_inboxlist($self->{imapd});
	my $res = PublicInbox::IMAP::cmd_list($self, 'tag', 'x', '%');
	is(scalar($$res =~ tr/\n/\n/), 2, 'only one result');
	like($$res, qr/ x\r\ntag OK/, 'saw expected');
	$res = PublicInbox::IMAP::cmd_list($self, 'tag', 'x.', '%');
	is(scalar($$res =~ tr/\n/\n/), 3, 'only one result');
	is(scalar(my @x = ($$res =~ m/ x\.[zy]\r\n/g)), 2, 'match expected');

	$res = PublicInbox::IMAP::cmd_list($self, 't', 'x.(?{die "RCE"})', '%');
	like($$res, qr/\At OK /, 'refname does not match attempted RCE');
	$res = PublicInbox::IMAP::cmd_list($self, 't', '', '(?{die "RCE"})%');
	like($$res, qr/\At OK /, 'wildcard does not match attempted RCE');
}

if ($ENV{TEST_BENCHMARK}) {
	use Benchmark qw(:all);
	my @n = map { { newsgroup => "inbox.comp.foo.bar.$_" } } (0..50000);
	push @n, map { { newsgroup => "xobni.womp.foo.bar.$_" } } (0..50000);
	my $self = { imapd => { grouplist => \@n } };
	PublicInbox::IMAPD::refresh_inboxlist($self->{imapd});

	my $n = scalar @n;
	open my $null, '>', '/dev/null' or die;
	my $ds = { sock => $null };
	my $nr = 200;
	diag "starting benchmark...";
	my $t = timeit(1, sub {
		for (0..$nr) {
			my $res = PublicInbox::IMAP::cmd_list($self, 'tag',
								'', '*');
			PublicInbox::DS::write($ds, $res);
		}
	});
	diag timestr($t). "list all for $n inboxes $nr times";
	$nr = 20;
	$t = timeit(1, sub {
		for (0..$nr) {
			my $res = PublicInbox::IMAP::cmd_list($self, 'tag',
								'inbox.', '%');
			PublicInbox::DS::write($ds, $res);
		}
	});
	diag timestr($t). "list partial for $n inboxes $nr times";
}

my $ret = $mic->search('all') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search all works');
$ret = $mic->search('uid 1') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search UID 1 works');
$ret = $mic->search('uid 1:1') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search UID 1:1 works');
$ret = $mic->search('uid 1:*') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search UID 1:* works');

is_deeply(scalar $mic->flags('1'), [], '->flags works');

for my $r ('1:*', '1') {
	$ret = $mic->fetch_hash($r, 'RFC822') or BAIL_OUT "FETCH $@";
	is_deeply([keys %$ret], [1]);
	like($ret->{1}->{RFC822}, qr/\r\n\r\nThis is a test/, 'read full');

	# ensure Mail::IMAPClient behaves
	my $str = $mic->message_string($r) or BAIL_OUT "->message_string: $@";
	is($str, $ret->{1}->{RFC822}, '->message_string works as expected');

	my $sz = $mic->fetch_hash($r, 'RFC822.size') or BAIL_OUT "FETCH $@";
	is($sz->{1}->{'RFC822.SIZE'}, length($ret->{1}->{RFC822}),
		'RFC822.SIZE');

	$ret = $mic->fetch_hash($r, 'RFC822.HEADER') or BAIL_OUT "FETCH $@";
	is_deeply([keys %$ret], [1]);
	like($ret->{1}->{'RFC822.HEADER'},
		qr/^Message-ID: <testmessage\@example\.com>/ms, 'read header');

	$ret = $mic->fetch_hash($r, 'INTERNALDATE') or BAIL_OUT "FETCH $@";
	is($ret->{1}->{'INTERNALDATE'}, '01-Jan-1970 00:00:00 +0000',
		'internaldate matches');
	ok(!$mic->fetch_hash($r, 'INFERNALDATE'), 'bogus attribute fails');

	my $envelope = $mic->get_envelope($r) or BAIL_OUT("get_envelope: $@");
	is($envelope->{bcc}, 'NIL', 'empty bcc');
	is($envelope->{messageid}, '<testmessage@example.com>', 'messageid');
	is(scalar @{$envelope->{to}}, 1, 'one {to} header');
	# *sigh* too much to verify...
	#use Data::Dumper; diag Dumper($envelope);

	$ret = $mic->fetch_hash($r, 'FLAGS') or BAIL_OUT "FETCH $@";
	is_deeply($ret->{1}->{FLAGS}, '', 'no flags');
}

# Mail::IMAPClient ->compress creates cyclic reference:
# https://rt.cpan.org/Ticket/Display.html?id=132654
my $compress_logout = sub {
	my ($c) = @_;
	ok($c->logout, 'logout ok after ->compress');
	# all documented in Mail::IMAPClient manpage:
	for (qw(Readmoremethod Readmethod Prewritemethod)) {
		$c->$_(undef);
	}
};

is_deeply([$mic->has_capability('COMPRESS')], ['DEFLATE'], 'deflate cap');
ok($mic->compress, 'compress enabled');
$compress_logout->($mic);

my $have_inotify = eval { require Linux::Inotify2; 1 };

my $pi_config = PublicInbox::Config->new;
$pi_config->each_inbox(sub {
	my ($ibx) = @_;
	my $env = { ORIGINAL_RECIPIENT => $ibx->{-primary_address} };
	my $name = $ibx->{name};
	my $ng = $ibx->{newsgroup};
	my $mic = Mail::IMAPClient->new(%mic_opt);
	ok($mic && $mic->login && $mic->IsAuthenticated, "authed $name");
	is_deeply([$mic->has_capability('IDLE')], ['IDLE'], "IDLE capa $name");
	ok(!$mic->idle, "IDLE fails w/o SELECT/EXAMINE $name");
	ok($mic->examine($ng), "EXAMINE $ng succeeds");
	ok($mic->idle, "IDLE succeeds on $ng");

	open(my $fh, '<', 't/data/message_embed.eml') or BAIL_OUT("open: $!");
	run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or
		BAIL_OUT('-mda delivery');
	my $t0 = Time::HiRes::time();
	ok(my @res = $mic->idle_data(11), "IDLE succeeds on $ng");
	is(grep(/\A\* [0-9] EXISTS\b/, @res), 1, 'got EXISTS message');
	ok((Time::HiRes::time() - $t0) < 10, 'IDLE client notified');

	my (@ino_info, $ino_fdinfo);
	SKIP: {
		skip 'no inotify support', 1 unless $have_inotify;
		skip 'missing /proc/$PID/fd', 1 if !-d "/proc/$td->{pid}/fd";
		my @ino = grep {
			readlink($_) =~ /\binotify\b/
		} glob("/proc/$td->{pid}/fd/*");
		is(scalar(@ino), 1, 'only one inotify FD');
		my $ino_fd = (split('/', $ino[0]))[-1];
		$ino_fdinfo = "/proc/$td->{pid}/fdinfo/$ino_fd";
		if (open my $fh, '<', $ino_fdinfo) {
			local $/ = "\n";
			@ino_info = grep(/^inotify wd:/, <$fh>);
			ok(scalar(@ino_info), 'inotify has watches');
		} else {
			skip "$ino_fdinfo missing: $!", 1;
		}
	};

	# ensure IDLE persists across HUP, w/o extra watches or FDs
	$td->kill('HUP') or BAIL_OUT "failed to kill -imapd: $!";
	SKIP: {
		skip 'no inotify fdinfo (or support)', 2 if !@ino_info;
		my (@tmp, %prev);
		local $/ = "\n";
		my $end = time + 5;
		until (time > $end) {
			select undef, undef, undef, 0.01;
			open my $fh, '<', $ino_fdinfo or
						BAIL_OUT "$ino_fdinfo: $!";
			%prev = map { $_ => 1 } @ino_info;
			@tmp = grep(/^inotify wd:/, <$fh>);
			if (scalar(@tmp) == scalar(@ino_info)) {
				delete @prev{@tmp};
				last if scalar(keys(%prev)) == @ino_info;
			}
		}
		is(scalar @tmp, scalar @ino_info,
			'old inotify watches replaced');
		is(scalar keys %prev, scalar @ino_info,
			'no previous watches overlap');
	};

	open($fh, '<', 't/data/0001.patch') or BAIL_OUT("open: $!");
	run_script(['-mda', '--no-precheck'], $env, { 0 => $fh }) or
		BAIL_OUT('-mda delivery');
	$t0 = Time::HiRes::time();
	ok(@res = $mic->idle_data(11), "IDLE succeeds on $ng after HUP");
	is(grep(/\A\* [0-9] EXISTS\b/, @res), 1, 'got EXISTS message');
	ok((Time::HiRes::time() - $t0) < 10, 'IDLE client notified');
});

$td->kill;
$td->join;
is($?, 0, 'no error in exited process');
open my $fh, '<', $err or BAIL_OUT("open $err failed: $!");
my $eout = do { local $/; <$fh> };
unlike($eout, qr/wide/i, 'no Wide character warnings');

done_testing;
