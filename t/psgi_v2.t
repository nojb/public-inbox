# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use PublicInbox::MIME;
use PublicInbox::Config;
use PublicInbox::WWW;
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
my @mids = $mime->header_obj->header_raw('Message-Id');
$new_mid = PublicInbox::MID::mid_clean($mids[0]);
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

@mids = $mime->header_obj->header_raw('Message-Id');
my $third = PublicInbox::MID::mid_clean($mids[0]);
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
		@from_ = ($raw =~ m/^From /mg);
		is(scalar(@from_), 3, 'three From_ lines in t.mbox.gz');
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
		like($raw, qr/&lt;\Q$mid\E&gt;/s, "Message-ID $mid shown");
	}
});

done_testing();

1;
