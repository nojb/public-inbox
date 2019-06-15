# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
require './t/common.perl';
require_git(2.6);
use File::Temp qw/tempdir/;
use PublicInbox::MIME;
use PublicInbox::Config;
use PublicInbox::WWW;
use PublicInbox::MID qw(mids);
my @mods = qw(DBD::SQLite Search::Xapian HTTP::Request::Common Plack::Test
		URI::Escape Plack::Builder);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for psgi_v2_dupes.t" if $@;
}
use_ok($_) for @mods;
use_ok 'PublicInbox::V2Writable';
my $mainrepo = tempdir('pi-v2_dupes-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => $mainrepo,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
my $new_mid;

my $im = PublicInbox::V2Writable->new($ibx, 1);
$im->{parallel} = 0;

my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		'Message-ID' => '<a-mid@b>',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
	],
	body => "hello world\n",
);
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

my $cfgpfx = "publicinbox.v2test";
my $cfg = {
	"$cfgpfx.address" => $ibx->{-primary_address},
	"$cfgpfx.mainrepo" => $mainrepo,
};
my $config = PublicInbox::Config->new($cfg);
my $www = PublicInbox::WWW->new($config);
my ($res, $raw, @from_);
test_psgi(sub { $www->call(@_) }, sub {
	my ($cb) = @_;
	$res = $cb->(GET('/v2test/a-mid@b/raw'));
	$raw = $res->content;
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
});

$mime->header_set('Message-Id', 'a-mid@b');
$mime->body_set("hello ghosts\n");
ok($im->add($mime), 'added 3rd duplicate-but-different message');
is(scalar(@warn), 2, 'got another warning');
like($warn[0], qr/mismatched/, 'warned about mismatched messages');
is($warn[0], $warn[1], 'both warnings are the same');

$mids = mids($mime->header_obj);
my $third = $mids->[-1];
$im->done;

test_psgi(sub { $www->call(@_) }, sub {
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
	$config->each_inbox(sub { $_[0]->search->reopen });

	SKIP: {
		eval { require IO::Uncompress::Gunzip };
		skip 'IO::Uncompress::Gunzip missing', 4 if $@;

		$res = $cb->(GET('/v2test/a-mid@b/t.mbox.gz'));
		my $out;
		my $in = $res->content;
		my $status = IO::Uncompress::Gunzip::gunzip(\$in => \$out);
		like($out, qr/^hello world$/m, 'got first in t.mbox.gz');
		like($out, qr/^hello world!$/m, 'got second in t.mbox.gz');
		like($out, qr/^hello ghosts$/m, 'got third in t.mbox.gz');
		@from_ = ($out =~ m/^From /mg);
		is(scalar(@from_), 3, 'three From_ lines in t.mbox.gz');

		# search interface
		$res = $cb->(POST('/v2test/?q=m:a-mid@b&x=m'));
		$in = $res->content;
		$status = IO::Uncompress::Gunzip::gunzip(\$in => \$out);
		like($out, qr/^hello world$/m, 'got first in mbox POST');
		like($out, qr/^hello world!$/m, 'got second in mbox POST');
		like($out, qr/^hello ghosts$/m, 'got third in mbox POST');
		@from_ = ($out =~ m/^From /mg);
		is(scalar(@from_), 3, 'three From_ lines in mbox POST');

		# all.mbox.gz interface
		$res = $cb->(GET('/v2test/all.mbox.gz'));
		$in = $res->content;
		$status = IO::Uncompress::Gunzip::gunzip(\$in => \$out);
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
	my @over = ($raw =~ m/\d{4}-\d+-\d+\s+\d+:\d+ (.+)$/gm);
	is_deeply(\@over, [ '<a', '` <a', '` <a' ], 'threaded messages show up');

	local $SIG{__WARN__} = 'DEFAULT';
	$res = $cb->(GET('/v2test/a-mid@b/'));
	$raw = $res->content;
	like($raw, qr/^hello world$/m, 'got first message');
	like($raw, qr/^hello world!$/m, 'got second message');
	like($raw, qr/^hello ghosts$/m, 'got third message');
	@from_ = ($raw =~ m/>From: /mg);
	is(scalar(@from_), 3, 'three From: lines');
	foreach my $mid ('a-mid@b', $new_mid, $third) {
		like($raw, qr/&lt;\Q$mid\E&gt;/s, "Message-ID $mid shown");
	}
	like($raw, qr/\b3\+ messages\b/, 'thread overview shown');

	my $exp = [ qw(<a-mid@b> <reuse@mid>) ];
	$mime->header_set('Message-Id', @$exp);
	$mime->header_set('Subject', '4th dupe');
	local $SIG{__WARN__} = sub {};
	ok($im->add($mime), 'added one message');
	$im->done;
	my @h = $mime->header('Message-ID');
	is_deeply($exp, \@h, 'reused existing Message-ID');

	$config->each_inbox(sub { $_[0]->search->reopen });

	$res = $cb->(GET('/v2test/new.atom'));
	my @ids = ($res->content =~ m!<id>urn:uuid:([^<]+)</id>!sg);
	my %ids;
	$ids{$_}++ for @ids;
	is_deeply([qw(1 1 1 1)], [values %ids], 'feed ids unique');

	$res = $cb->(GET('/v2test/reuse@mid/T/'));
	$raw = $res->content;
	like($raw, qr/\b4\+ messages\b/, 'thread overview shown with /T/');
	@over = ($raw =~ m/^\d{4}-\d+-\d+\s+\d+:\d+ (.+)$/gm);
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
	is($res->code, 404, 'unpartitioned git URL fails');

	# ensure conflicted attachments can be resolved
	foreach my $body (qw(old new)) {
		my $parts = [
			PublicInbox::MIME->create(
				attributes => { content_type => 'text/plain' },
				body => 'blah',
			),
			PublicInbox::MIME->create(
				attributes => {
					filename => 'attach.txt',
					content_type => 'text/plain',
				},
				body => $body
			)
		];
		$mime = PublicInbox::MIME->create(
			parts => $parts,
			header_str => [ From => 'root@z',
				'Message-ID' => '<a@dup>',
				Subject => 'hi']
		);
		ok($im->add($mime), "added attachment $body");
	}
	$im->done;
	$config->each_inbox(sub { $_[0]->search->reopen });
	$res = $cb->(GET('/v2test/a@dup/'));
	my @links = ($res->content =~ m!"\.\./([^/]+/2-attach\.txt)\"!g);
	is(scalar(@links), 2, 'both attachment links exist');
	isnt($links[0], $links[1], 'attachment links are different');
	{
		my $old = $cb->(GET('/v2test/' . $links[0]));
		my $new = $cb->(GET('/v2test/' . $links[1]));
		is($old->content, 'old', 'got expected old content');
		is($new->content, 'new', 'got expected new content');
	}
});

done_testing();

1;
