# Copyright (C) 2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::MIME;
use File::Temp qw/tempdir/;
use Fcntl qw(SEEK_SET);
use Cwd;

my $V = 2;
foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for v2mda.t" if $@;
}
use_ok 'PublicInbox::V2Writable';
my $tmpdir = tempdir('pi-v2mda-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $ibx = {
	mainrepo => "$tmpdir/inbox",
	name => 'test-v2writable',
	address => [ 'test@example.com' ],
};
my $mime = PublicInbox::MIME->create(
	header => [
		From => 'a@example.com',
		To => 'test@example.com',
		Subject => 'this is a subject',
		Date => 'Fri, 02 Oct 1993 00:00:00 +0000',
		'Message-ID' => '<foo@bar>',
		'List-ID' => '<test.example.com>',
	],
	body => "hello world\n",
);

my $mda = "blib/script/public-inbox-mda";
ok(-f "blib/script/public-inbox-mda", '-mda exists');
my $main_bin = getcwd()."/t/main-bin";
local $ENV{PI_DIR} = "$tmpdir/foo";
local $ENV{PATH} = "$main_bin:blib/script:$ENV{PATH}";
local $ENV{PI_EMERGENCY} = "$tmpdir/fail";
ok(mkdir "$tmpdir/fail");

my @cmd = (qw(public-inbox-init), "-V$V", $ibx->{name},
		$ibx->{mainrepo}, 'http://localhost/test',
		$ibx->{address}->[0]);
ok(PublicInbox::Import::run_die(\@cmd), 'initialized v2 inbox');

open my $tmp, '+>', undef or die "failed to open anonymous tempfile: $!";
ok($tmp->print($mime->as_string), 'wrote to temporary file');
ok($tmp->flush, 'flushed temporary file');
ok($tmp->sysseek(0, SEEK_SET), 'seeked');

my $rdr = { 0 => fileno($tmp) };
local $ENV{ORIGINAL_RECIPIENT} = 'test@example.com';
ok(PublicInbox::Import::run_die(['public-inbox-mda'], undef, $rdr),
	'mda delivered a message');

$ibx = PublicInbox::Inbox->new($ibx);

if ($V == 1) {
	my $cmd = [ 'public-inbox-index', "$tmpdir/inbox" ];
	ok(PublicInbox::Import::run_die($cmd, undef, $rdr), 'v1 indexed');
}
my $msgs = $ibx->search->query('');
my $saved = $ibx->smsg_mime($msgs->[0]);
is($saved->{mime}->as_string, $mime->as_string, 'injected message');

my $patch = 't/data/0001.patch';
open my $fh, '<', $patch or die "failed to open $patch: $!\n";
$rdr = { 0 => fileno($fh) };
ok(PublicInbox::Import::run_die(['public-inbox-mda'], undef, $rdr),
	'mda delivered a patch');
my $post = $ibx->search->reopen->query('dfpost:6e006fd7');
is(scalar(@$post), 1, 'got one result for dfpost');
my $pre = $ibx->search->query('dfpre:090d998');
is(scalar(@$pre), 1, 'got one result for dfpre');
is($post->[0]->{blob}, $pre->[0]->{blob}, 'same message in both cases');
done_testing();
