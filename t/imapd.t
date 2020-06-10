#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# end-to-end IMAP tests, see unit tests in t/imap.t, too
use strict;
use Test::More;
use Time::HiRes ();
use PublicInbox::TestCommon;
use PublicInbox::Config;
use PublicInbox::Spawn qw(which);
require_mods(qw(DBD::SQLite Mail::IMAPClient Mail::IMAPClient::BodyStructure));
my $imap_client = 'Mail::IMAPClient';
my $can_compress = $imap_client->can('compress');
if ($can_compress) { # hope this gets fixed upstream, soon
	require PublicInbox::IMAPClient;
	$imap_client = 'PublicInbox::IMAPClient';
}

require_ok 'PublicInbox::IMAP';
my $first_range = '0';

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
my $mic = $imap_client->new(%mic_opt);
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
$mic = $imap_client->new(%mic_opt);
ok($mic && $mic->login && $mic->IsAuthenticated, 'AUTHENTICATE ANONYMOUS');
my $post_auth_anon_capa = $mic->capability;
is_deeply($post_auth_anon_capa, $post_login_capa,
	'auth anon has same capabilities');
my $e;
ok(!$mic->examine('foo') && ($e = $@), 'EXAMINE non-existent');
like($e, qr/\bNO\b/, 'got a NO on EXAMINE for non-existent');
ok(!$mic->select('foo') && ($e = $@), 'EXAMINE non-existent');
like($e, qr/\bNO\b/, 'got a NO on EXAMINE for non-existent');
my $mailbox1 = "inbox.i1.$first_range";
ok($mic->select('inbox.i1'), 'SELECT on parent succeeds');
ok($mic->select($mailbox1), 'SELECT succeeds');
ok($mic->examine($mailbox1), 'EXAMINE succeeds');
my @raw = $mic->status($mailbox1, qw(Messages uidnext uidvalidity));
is(scalar(@raw), 2, 'got status response');
like($raw[0], qr/\A\*\x20STATUS\x20inbox\.i1\.$first_range\x20
	\(MESSAGES\x20\d+\x20UIDNEXT\x20\d+\x20UIDVALIDITY\x20\d+\)\r\n/sx);
like($raw[1], qr/\A\S+ OK /, 'finished status response');

my @orig_list = @raw = $mic->list;
like($raw[0], qr/^\* LIST \(.*?\) "\." INBOX/,
	'got an inbox');
like($raw[-1], qr/^\S+ OK /, 'response ended with OK');
is(scalar(@raw), scalar(@V) + 4, 'default LIST response');
@raw = $mic->list('', 'inbox.i1');
is(scalar(@raw), 2, 'limited LIST response');
like($raw[0], qr/^\* LIST \(.*?\) "\." INBOX/,
		'got an inbox.i1');
like($raw[-1], qr/^\S+ OK /, 'response ended with OK');

my $ret = $mic->search('all') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search all works');
$ret = $mic->search('uid 1') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search UID 1 works');
$ret = $mic->search('uid 1:1') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search UID 1:1 works');
$ret = $mic->search('uid 1:*') or BAIL_OUT "SEARCH FAIL $@";
is_deeply($ret, [ 1 ], 'search UID 1:* works');

is_deeply(scalar $mic->flags('1'), [], '->flags works');
{
	# RFC 3501 section 6.4.8 states:
	# Also note that a UID range of 559:* always includes the
	# UID of the last message in the mailbox, even if 559 is
	# higher than any assigned UID value.
	my $exp = $mic->fetch_hash(1, 'UID');
	$ret = $mic->fetch_hash('559:*', 'UID');
	is_deeply($ret, $exp, 'beginning range too big');
	for my $r (qw(559:558 558:559)) {
		$ret = $mic->fetch_hash($r, 'UID');
		is_deeply($ret, {}, "out-of-range UID FETCH $r");
	}
}

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

	$ret = $mic->fetch_hash($r, 'BODY[1]') or BAIL_OUT "FETCH $@";
	like($ret->{1}->{'BODY[1]'}, qr/\AThis is a test message/, 'BODY[1]');

	$ret = $mic->fetch_hash($r, 'BODY[1]<1>') or BAIL_OUT "FETCH $@";
	like($ret->{1}->{'BODY[1]<1>'}, qr/\Ahis is a test message/,
			'BODY[1]<1>');

	$ret = $mic->fetch_hash($r, 'BODY[1]<2.3>') or BAIL_OUT "FETCH $@";
	is($ret->{1}->{'BODY[1]<2>'}, "is ", 'BODY[1]<2.3>');
	$ret = $mic->bodypart_string($r, 1, 3, 2) or
					BAIL_OUT "bodypart_string $@";
	is($ret, "is ", 'bodypart string');

	$ret = $mic->fetch_hash($r, 'BODY[HEADER.FIELDS.NOT (Message-ID)]')
		or BAIL_OUT "FETCH $@";
	$ret = $ret->{1}->{'BODY[HEADER.FIELDS.NOT (MESSAGE-ID)]'};
	unlike($ret, qr/message-id/i, 'Message-ID excluded');
	like($ret, qr/\r\n\r\n\z/s, 'got header end');

	$ret = $mic->fetch_hash($r, 'BODY[HEADER.FIELDS (Message-ID)]')
		or BAIL_OUT "FETCH $@";
	is($ret->{1}->{'BODY[HEADER.FIELDS (MESSAGE-ID)]'},
		'Message-ID: <testmessage@example.com>'."\r\n\r\n",
		'got only Message-ID');

	my $bs = $mic->get_bodystructure($r) or BAIL_OUT("bodystructure: $@");
	ok($bs, 'got a bodystructure');
	is(lc($bs->bodytype), 'text', '->bodytype');
	is(lc($bs->bodyenc), '8bit', '->bodyenc');
}

is_deeply([$mic->has_capability('COMPRESS')], ['DEFLATE'], 'deflate cap');
SKIP: {
	skip 'Mail::IMAPClient too old for ->compress', 2 if !$can_compress;
	my $c = $imap_client->new(%mic_opt);
	ok($c && $c->compress, 'compress enabled');
	ok($c->examine($mailbox1), 'EXAMINE succeeds after COMPRESS');
	$ret = $c->search('uid 1:*') or BAIL_OUT "SEARCH FAIL $@";
	is_deeply($ret, [ 1 ], 'search UID 1:* works after compression');
}

ok($mic->logout, 'logout works');

my $have_inotify = eval { require Linux::Inotify2; 1 };

my $pi_config = PublicInbox::Config->new;
$pi_config->each_inbox(sub {
	my ($ibx) = @_;
	my $env = { ORIGINAL_RECIPIENT => $ibx->{-primary_address} };
	my $name = $ibx->{name};
	my $ng = $ibx->{newsgroup};
	my $mic = $imap_client->new(%mic_opt);
	ok($mic && $mic->login && $mic->IsAuthenticated, "authed $name");
	my $mb = "$ng.$first_range";
	my $uidnext = $mic->uidnext($mb); # we'll fetch BODYSTRUCTURE on this
	ok($uidnext, 'got uidnext for later fetch');
	is_deeply([$mic->has_capability('IDLE')], ['IDLE'], "IDLE capa $name");
	ok(!$mic->idle, "IDLE fails w/o SELECT/EXAMINE $name");
	ok($mic->examine($mb), "EXAMINE $ng succeeds");
	ok(my $idle_tag = $mic->idle, "IDLE succeeds on $ng");

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
	ok($mic->done($idle_tag), 'IDLE DONE');
	my $bs = $mic->get_bodystructure($uidnext);
	ok($bs, 'BODYSTRUCTURE ok for deeply nested');
	$ret = $mic->fetch_hash($uidnext, 'BODY') or BAIL_OUT "FETCH $@";
	ok($ret->{$uidnext}->{BODY}, 'got something in BODY');

	# this matches dovecot behavior
	$ret = $mic->fetch_hash($uidnext, 'BODY[1]') or BAIL_OUT "FETCH $@";
	is($ret->{$uidnext}->{'BODY[1]'},
		"testing embedded message harder\r\n", 'BODY[1]');
	$ret = $mic->fetch_hash($uidnext, 'BODY[2]') or BAIL_OUT "FETCH $@";
	like($ret->{$uidnext}->{'BODY[2]'},
		qr/\ADate: Sat, 18 Apr 2020 22:20:20 /, 'BODY[2]');

	$ret = $mic->fetch_hash($uidnext, 'BODY[2.1.1]') or BAIL_OUT "FETCH $@";
	is($ret->{$uidnext}->{'BODY[2.1.1]'},
		"testing embedded message\r\n", 'BODY[2.1.1]');

	$ret = $mic->fetch_hash($uidnext, 'BODY[2.1.2]') or BAIL_OUT "FETCH $@";
	like($ret->{$uidnext}->{'BODY[2.1.2]'}, qr/\AFrom: /,
		'BODY[2.1.2] tip matched');
	like($ret->{$uidnext}->{'BODY[2.1.2]'},
		 # trailing CRLF may vary depending on MIME parser
		 qr/done_testing;(?:\r\n){1,2}\z/,
		'BODY[2.1.2] tail matched');

	$ret = $mic->fetch_hash("1:$uidnext", 'BODY[2.HEADER]') or
						BAIL_OUT "2.HEADER $@";
	like($ret->{$uidnext}->{'BODY[2.HEADER]'},
		qr/\ADate: Sat, 18 Apr 2020 22:20:20 /,
		'2.HEADER of message/rfc822');

	$ret = $mic->fetch_hash($uidnext, 'BODY[2.MIME]') or
		BAIL_OUT "2.MIME $@";
	is($ret->{$uidnext}->{'BODY[2.MIME]'}, <<EOF, 'BODY[2.MIME]');
Content-Type: message/rfc822\r
Content-Disposition: attachment; filename="embed2x\.eml"\r
\r
EOF

	my @hits = $mic->search('SENTON' => '18-Apr-2020');
	is_deeply(\@hits, [ $uidnext ], 'search with date condition works');
	ok($mic->examine($ng), 'EXAMINE on dummy');
	@hits = $mic->search('SENTSINCE' => '18-Apr-2020');
	is_deeply(\@hits, [], 'search on dummy with condition works');
}); # each_inbox

# message sequence numbers :<
is($mic->Uid(0), 0, 'disable UID on '.ref($mic));
ok($mic->reconnect, 'reconnected');
$ret = $mic->fetch_hash('1,2:3', 'RFC822') or BAIL_OUT "FETCH $@";
is(scalar keys %$ret, 3, 'got all 3 messages with comma-separated sequence');
$ret = $mic->fetch_hash('1:*', 'RFC822') or BAIL_OUT "FETCH $@";
is(scalar keys %$ret, 3, 'got all 3 messages');
{
	my $rdr = { 0 => \($ret->{1}->{RFC822}) };
	my $env = { HOME => $ENV{HOME} };
	my @cmd = qw(-learn rm --all);
	run_script(\@cmd, $env, $rdr) or BAIL_OUT('-learn rm');
}
my $r2 = $mic->fetch_hash('1:*', 'BODY.PEEK[]') or BAIL_OUT "FETCH $@";
is(scalar keys %$r2, 2, 'did not get all 3 messages');
is($r2->{1}->{'BODY[]'}, $ret->{2}->{RFC822}, 'message 2 unchanged');
is($r2->{2}->{'BODY[]'}, $ret->{3}->{RFC822}, 'message 3 unchanged');
$r2 = $mic->fetch_hash(2, 'BODY.PEEK[HEADER.FIELDS (message-id)]')
			or BAIL_OUT "FETCH $@";
is($r2->{2}->{'BODY[HEADER.FIELDS (MESSAGE-ID)]'},
	'Message-ID: <20200418222508.GA13918@dcvr>'."\r\n\r\n",
	'BODY.PEEK[HEADER.FIELDS ...] drops .PEEK');

{
	my @new_list = $mic->list;
	# tag differs in [-1]
	like($orig_list[-1], qr/\A\S+ OK List done\r\n/, 'orig LIST');
	like($new_list[-1], qr/\A\S+ OK List done\r\n/, 'new LIST');
	pop @new_list;
	pop @orig_list;
	# TODO: not sure if sort order matters, imapd_refresh_finalize
	# sorts, for now, but maybe clients don't care...
	is_deeply(\@new_list, \@orig_list, 'LIST identical');
}
ok($mic->close, 'CLOSE works');
ok(!$mic->close, 'CLOSE not idempotent');
ok($mic->logout, 'logged out');

{
	my $c = tcp_connect($sock);
	$c->autoflush(1);
	like(<$c>, qr/\* OK/, 'got a greeting');
	print $c "\r\n";
	like(<$c>, qr/\A\* BAD Error in IMAP command/, 'empty line');
	print $c "tagonly\r\n";
	like(<$c>, qr/\Atagonly BAD Error in IMAP command/, 'tag-only line');
}

$td->kill;
$td->join;
is($?, 0, 'no error in exited process');
open my $fh, '<', $err or BAIL_OUT("open $err failed: $!");
my $eout = do { local $/; <$fh> };
unlike($eout, qr/wide/i, 'no Wide character warnings');
unlike($eout, qr/uninitialized/i, 'no uninitialized warnings');

done_testing;
