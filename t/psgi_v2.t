# Copyright (C) 2018-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
require_git(2.6);
use PublicInbox::Eml;
use PublicInbox::Config;
use PublicInbox::MID qw(mids);
require_mods(qw(DBD::SQLite Search::Xapian HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder));
use_ok($_) for (qw(HTTP::Request::Common Plack::Test));
use_ok 'PublicInbox::WWW';
use_ok 'PublicInbox::V2Writable';
my ($inboxdir, $for_destroy) = tmpdir();
my $cfgpath = "$inboxdir/$$.config";
SKIP: {
	require_mods(qw(Plack::Test::ExternalServer), 1);
	open my $fh, '>', $cfgpath or BAIL_OUT $!;
	print $fh <<EOF or BAIL_OUT $!;
[publicinbox "v2test"]
	inboxdir = $inboxdir
	address = test\@example.com
EOF
	close $fh or BAIL_OUT $!;
}

my $run_httpd = sub {
	my ($client, $skip) = @_;
	SKIP: {
		require_mods(qw(Plack::Test::ExternalServer), $skip);
		my $env = { PI_CONFIG => $cfgpath };
		my $sock = tcp_server() or die;
		my ($out, $err) = map { "$inboxdir/std$_.log" } qw(out err);
		my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
		my $td = start_script($cmd, $env, { 3 => $sock });
		my ($h, $p) = ($sock->sockhost, $sock->sockport);
		local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = "http://$h:$p";
		Plack::Test::ExternalServer::test_psgi(client => $client);
		$td->join('TERM');
		open my $fh, '<', $err or BAIL_OUT $!;
		my $e = do { local $/; <$fh> };
		if ($e =~ s/^Plack::Middleware::ReverseProxy missing,\n//gms) {
			$e =~ s/^URL generation for redirects .*\n//gms;
		}
		is($e, '', 'no errors');
	}
};

my $ibx = {
	inboxdir => $inboxdir,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $new_mid;

my $im = PublicInbox::V2Writable->new($ibx, 1);
$im->{parallel} = 0;

my $mime = PublicInbox::Eml->new(<<'EOF');
From oldbug-pre-a0c07cba0e5d8b6a Fri Oct  2 00:00:00 1993
From: a@example.com
To: test@example.com
Subject: this is a subject
Message-ID: <a-mid@b>
Date: Fri, 02 Oct 1993 00:00:00 +0000

hello world
EOF
ok($im->add($mime), 'added one message');
$mime->body_set("hello world!\n");

my @warn;
local $SIG{__WARN__} = sub { push @warn, @_ };
$mime->header_set(Date => 'Fri, 02 Oct 1993 00:01:00 +0000');
ok($im->add($mime), 'added duplicate-but-different message');
is(scalar(@warn), 1, 'got one warning');
my $mids = mids($mime->header_obj);
$new_mid = $mids->[1];
$im->done;

my $msg = $ibx->msg_by_mid('a-mid@b');
like($$msg, qr/\AFrom oldbug/s,
	'"From_" line stored to test old bug workaround');

my $cfgpfx = "publicinbox.v2test";
my $cfg = PublicInbox::Config->new(\<<EOF);
$cfgpfx.address=$ibx->{-primary_address}
$cfgpfx.inboxdir=$inboxdir
EOF
my $www = PublicInbox::WWW->new($cfg);
my ($res, $raw, @from_);
my $client0 = sub {
	my ($cb) = @_;
	$res = $cb->(GET('/v2test/description'));
	like($res->content, qr!\$INBOX_DIR/description missing!,
		'got v2 description missing message');
	$res = $cb->(GET('/v2test/a-mid@b/raw'));
	$raw = $res->content;
	unlike($raw, qr/^From oldbug/sm, 'buggy "From_" line omitted');
	like($raw, qr/^hello world$/m, 'got first message');
	like($raw, qr/^hello world!$/m, 'got second message');
	@from_ = ($raw =~ m/^From /mg);
	is(scalar(@from_), 2, 'two From_ lines');

	$res = $cb->(GET("/v2test/$new_mid/raw"));
	$raw = $res->content;
	like($raw, qr/^hello world!$/m, 'second message with new Message-Id');
	@from_ = ($raw =~ m/^From /mg);
	is(scalar(@from_), 1, 'only one From_ line');

	# Atom feed should sort by Date: (if Received is missing)
	$res = $cb->(GET('/v2test/new.atom'));
	my @bodies = ($res->content =~ />(hello [^<]+)</mg);
	is_deeply(\@bodies, [ "hello world!\n", "hello world\n" ],
		'Atom ordering is chronological');

	# new.html should sort by Date:, too (if Received is missing)
	$res = $cb->(GET('/v2test/new.html'));
	@bodies = ($res->content =~ /^(hello [^<]+)$/mg);
	is_deeply(\@bodies, [ "hello world!\n", "hello world\n" ],
		'new.html ordering is chronological');
};
test_psgi(sub { $www->call(@_) }, $client0);
$run_httpd->($client0, 9);

$mime->header_set('Message-Id', 'a-mid@b');
$mime->body_set("hello ghosts\n");
ok($im->add($mime), 'added 3rd duplicate-but-different message');
is(scalar(@warn), 2, 'got another warning');
like($warn[0], qr/mismatched/, 'warned about mismatched messages');
is($warn[0], $warn[1], 'both warnings are the same');

$mids = mids($mime->header_obj);
my $third = $mids->[-1];
$im->done;

my $client1 = sub {
	my ($cb) = @_;
	$res = $cb->(GET("/v2test/$third/raw"));
	$raw = $res->content;
	like($raw, qr/^hello ghosts$/m, 'got third message');
	@from_ = ($raw =~ m/^From /mg);
	is(scalar(@from_), 1, 'one From_ line');

	$res = $cb->(GET('/v2test/a-mid@b/raw'));
	$raw = $res->content;
	like($raw, qr/^hello world$/m, 'got first message');
	like($raw, qr/^hello world!$/m, 'got second message');
	like($raw, qr/^hello ghosts$/m, 'got third message');
	@from_ = ($raw =~ m/^From /mg);
	is(scalar(@from_), 3, 'three From_ lines');
	$cfg->each_inbox(sub { $_[0]->search->reopen });

	SKIP: {
		eval { require IO::Uncompress::Gunzip };
		skip 'IO::Uncompress::Gunzip missing', 6 if $@;
		my ($in, $out, $status);
		my $req = GET('/v2test/a-mid@b/raw');
		$req->header('Accept-Encoding' => 'gzip');
		$res = $cb->($req);
		is($res->header('Content-Encoding'), 'gzip', 'gzip encoding');
		$in = $res->content;
		IO::Uncompress::Gunzip::gunzip(\$in => \$out);
		is($out, $raw, 'gzip response matches');

		$res = $cb->(GET('/v2test/a-mid@b/t.mbox.gz'));
		$in = $res->content;
		$status = IO::Uncompress::Gunzip::gunzip(\$in => \$out);
		unlike($out, qr/^From oldbug/sm, 'buggy "From_" line omitted');
		like($out, qr/^hello world$/m, 'got first in t.mbox.gz');
		like($out, qr/^hello world!$/m, 'got second in t.mbox.gz');
		like($out, qr/^hello ghosts$/m, 'got third in t.mbox.gz');
		@from_ = ($out =~ m/^From /mg);
		is(scalar(@from_), 3, 'three From_ lines in t.mbox.gz');

		# search interface
		$res = $cb->(POST('/v2test/?q=m:a-mid@b&x=m'));
		$in = $res->content;
		$status = IO::Uncompress::Gunzip::gunzip(\$in => \$out);
		unlike($out, qr/^From oldbug/sm, 'buggy "From_" line omitted');
		like($out, qr/^hello world$/m, 'got first in mbox POST');
		like($out, qr/^hello world!$/m, 'got second in mbox POST');
		like($out, qr/^hello ghosts$/m, 'got third in mbox POST');
		@from_ = ($out =~ m/^From /mg);
		is(scalar(@from_), 3, 'three From_ lines in mbox POST');

		# all.mbox.gz interface
		$res = $cb->(GET('/v2test/all.mbox.gz'));
		$in = $res->content;
		$status = IO::Uncompress::Gunzip::gunzip(\$in => \$out);
		unlike($out, qr/^From oldbug/sm, 'buggy "From_" line omitted');
		like($out, qr/^hello world$/m, 'got first in all.mbox');
		like($out, qr/^hello world!$/m, 'got second in all.mbox');
		like($out, qr/^hello ghosts$/m, 'got third in all.mbox');
		@from_ = ($out =~ m/^From /mg);
		is(scalar(@from_), 3, 'three From_ lines in all.mbox');
	};

	$res = $cb->(GET('/v2test/?q=m:a-mid@b&x=t'));
	is($res->code, 200, 'success with threaded search');
	my $raw = $res->content;
	ok($raw =~ s/\A.*>Results 1-3 of 3\b//s, 'got all results');
	my @over = ($raw =~ m/\d{4}-\d+-\d+\s+\d+:\d+ +(?:\d+\% )?(.+)$/gm);
	is_deeply(\@over, [ '<a', '` <a', '` <a' ], 'threaded messages show up');

	$res = $cb->(GET('/v2test/?q=m:a-mid@b&x=A'));
	is($res->code, 200, 'success with Atom search');
	SKIP: {
		require_mods(qw(XML::TreePP), 2);
		my $t = XML::TreePP->new->parse($res->content);
		like($t->{feed}->{-xmlns}, qr/\bAtom\b/,
			'looks like an an Atom feed');
		is(scalar @{$t->{feed}->{entry}}, 3, 'parsed three entries');
	};

	local $SIG{__WARN__} = 'DEFAULT';
	$res = $cb->(GET('/v2test/a-mid@b/'));
	$raw = $res->content;
	like($raw, qr/^hello world$/m, 'got first message');
	like($raw, qr/^hello world!$/m, 'got second message');
	like($raw, qr/^hello ghosts$/m, 'got third message');
	@from_ = ($raw =~ m/>From: /mg);
	is(scalar(@from_), 3, 'three From: lines');
	foreach my $mid ('a-mid@b', $new_mid, $third) {
		like($raw, qr!>\Q$mid\E</a>!s, "Message-ID $mid shown");
	}
	like($raw, qr/\b3\+ messages\b/, 'thread overview shown');
};

test_psgi(sub { $www->call(@_) }, $client1);
$run_httpd->($client1, 38);

{
	my $exp = [ qw(<a-mid@b> <reuse@mid>) ];
	$mime->header_set('Message-Id', @$exp);
	$mime->header_set('Subject', '4th dupe');
	local $SIG{__WARN__} = sub {};
	ok($im->add($mime), 'added one message');
	$im->done;
	my @h = $mime->header('Message-ID');
	is_deeply($exp, \@h, 'reused existing Message-ID');
	$cfg->each_inbox(sub { $_[0]->search->reopen });
}

my $client2 = sub {
	my ($cb) = @_;
	my $res = $cb->(GET('/v2test/new.atom'));
	my @ids = ($res->content =~ m!<id>urn:uuid:([^<]+)</id>!sg);
	my %ids;
	$ids{$_}++ for @ids;
	is_deeply([qw(1 1 1 1)], [values %ids], 'feed ids unique');

	$res = $cb->(GET('/v2test/reuse@mid/T/'));
	$raw = $res->content;
	like($raw, qr/\b4\+ messages\b/, 'thread overview shown with /T/');
	my @over = ($raw =~ m/^\d{4}-\d+-\d+\s+\d+:\d+ (.+)$/gm);
	is_deeply(\@over, [ '<a', '` <a', '` <a', '` <a' ],
		'duplicate messages share the same root');

	$res = $cb->(GET('/v2test/reuse@mid/t/'));
	$raw = $res->content;
	like($raw, qr/\b4\+ messages\b/, 'thread overview shown with /t/');

	$res = $cb->(GET('/v2test/0/info/refs'));
	is($res->code, 200, 'got info refs for dumb clones');
	$res = $cb->(GET('/v2test/0.git/info/refs'));
	is($res->code, 200, 'got info refs for dumb clones w/ .git suffix');
	$res = $cb->(GET('/v2test/info/refs'));
	is($res->code, 404, 'v2 git URL w/o shard fails');
};

test_psgi(sub { $www->call(@_) }, $client2);
$run_httpd->($client2, 8);
{
	# ensure conflicted attachments can be resolved
	foreach my $body (qw(old new)) {
		$mime = eml_load "t/psgi_v2-$body.eml";
		ok($im->add($mime), "added attachment $body");
	}
	$im->done;
	$cfg->each_inbox(sub { $_[0]->search->reopen });
}

my $client3 = sub {
	my ($cb) = @_;
	my $res = $cb->(GET('/v2test/a@dup/'));
	my @links = ($res->content =~ m!"\.\./([^/]+/2-attach\.txt)\"!g);
	is(scalar(@links), 2, 'both attachment links exist');
	isnt($links[0], $links[1], 'attachment links are different');
	{
		my $old = $cb->(GET('/v2test/' . $links[0]));
		my $new = $cb->(GET('/v2test/' . $links[1]));
		is($old->content, 'old', 'got expected old content');
		is($new->content, 'new', 'got expected new content');
	}
	$res = $cb->(GET('/v2test/?t=1970'.'01'.'01'.'000000'));
	is($res->code, 404, '404 for out-of-range t= param');
	@warn = ();
	$res = $cb->(GET('/v2test/?t=1970'.'01'.'01'));
	is_deeply(\@warn, [], 'no warnings on YYYYMMDD only');
};
test_psgi(sub { $www->call(@_) }, $client3);
$run_httpd->($client3, 4);

done_testing();

1;
