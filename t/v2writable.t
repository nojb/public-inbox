# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use PublicInbox::ContentId qw(content_digest);
use File::Temp qw/tempdir/;
foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for nntpd.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
my $mainrepo = tempdir('pi-v2writable-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => $mainrepo,
	name => 'test-v2writable',
	version => 2,
	-primary_address => 'test@example.com',
};
$ibx = PublicInbox::Inbox->new($ibx);
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

my $im = PublicInbox::V2Writable->new($ibx, 1);
ok($im->add($mime), 'ordinary message added');
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	is(undef, $im->add($mime), 'obvious duplicate rejected');
	like(join(' ', @warn), qr/resent/, 'warned about resent message');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>', '<c@d>');
	ok($im->add($mime), 'secondary MID used');
	like(join(' ', @warn), qr/mismatched/, 'warned about mismatch');
	like(join(' ', @warn), qr/alternative/, 'warned about alternative');
	is_deeply([ '<a-mid@b>', '<c@d>' ],
		[ $mime->header_obj->header_raw('Message-Id') ],
		'no new Message-Id added');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>');
	$mime->body_set('different');
	ok($im->add($mime), 'reused mid ok');
	like(join(' ', @warn), qr/reused/, 'warned about reused MID');
	my @mids = $mime->header_obj->header_raw('Message-Id');
	is($mids[1], '<a-mid@b>', 'original mid not changed');
	like($mids[0], qr/\A<\w+\@localhost>\z/, 'new MID added');
	is(scalar(@mids), 2, 'only one new MID added');

	@warn = ();
	$mime->header_set('Message-Id', '<a-mid@b>');
	$mime->body_set('this one needs a random mid');
	my $gen = content_digest($mime)->hexdigest . '@localhost';
	my $fake = PublicInbox::MIME->new($mime->as_string);
	$fake->header_set('Message-Id', $gen);
	ok($im->add($fake), 'fake added easily');
	is_deeply(\@warn, [], 'no warnings from a faker');
	ok($im->add($mime), 'random MID made');
	like(join(' ', @warn), qr/using random/, 'warned about using random');
	@mids = $mime->header_obj->header_raw('Message-Id');
	is($mids[1], '<a-mid@b>', 'original mid not changed');
	like($mids[0], qr/\A<\w+\@localhost>\z/, 'new MID added');
	is(scalar(@mids), 2, 'only one new MID added');

	@warn = ();
	$mime->header_set('Message-Id');
	ok($im->add($mime), 'random MID made for MID free message');
	@mids = $mime->header_obj->header_raw('Message-Id');
	like($mids[0], qr/\A<\w+\@localhost>\z/, 'mid was generated');
	is(scalar(@mids), 1, 'new generated');
}

{
	$mime->header_set('Message-Id', '<abcde@1>', '<abcde@2>');
	ok($im->add($mime), 'message with multiple Message-ID');
	$im->done;
	my @found;
	$ibx->search->each_smsg_by_mid('abcde@1', sub { push @found, @_; 1 });
	is(scalar(@found), 1, 'message found by first MID');
	$ibx->search->each_smsg_by_mid('abcde@2', sub { push @found, @_; 1 });
	is(scalar(@found), 2, 'message found by second MID');
	is($found[0]->{doc_id}, $found[1]->{doc_id}, 'same document');
	ok($found[1]->{doc_id} > 0, 'doc_id is positive');
}


done_testing();
