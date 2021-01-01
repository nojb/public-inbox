#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# we can index a message from a mirror which bypasses dedupe.
use strict;
use Test::More;
use PublicInbox::TestCommon;
require_git(2.6);
require_mods(qw(DBD::SQLite));
my ($tmpdir, $for_destroy) = tmpdir();
use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Git';
use_ok 'PublicInbox::InboxWritable';
my $ibx = PublicInbox::InboxWritable->new({
	inboxdir => $tmpdir,
	name => 'test-v2dupindex',
	version => 2,
	indexlevel => 'basic',
	-primary_address => 'test@example.com',
}, { nproc => 1 });
$ibx->init_inbox(1);
my $v2w = $ibx->importer;
$v2w->add(eml_load('t/plack-qp.eml'));
$v2w->add(eml_load('t/mda-mime.eml'));
$v2w->done;

my $git0 = PublicInbox::Git->new("$tmpdir/git/0.git");
my $im = PublicInbox::Import->new($git0, undef, undef, $ibx);
$im->{path_type} = 'v2';
$im->{lock_path} = undef;

# bypass duplicate filters (->header_set is optional)
my $eml = eml_load('t/plack-qp.eml');
$eml->header_set('X-This-Is-Not-Checked-By-ContentHash', 'blah');
ok($im->add($eml), 'add seen message directly');
ok($im->add(eml_load('t/mda-mime.eml')), 'add another seen message directly');

ok($im->add(eml_load('t/iso-2202-jp.eml')), 'add another new message');
$im->done;

# mimic a fresh clone by dropping indices
my @sqlite = (glob("$tmpdir/*sqlite3*"), glob("$tmpdir/xap*/*sqlite3*"));
is(unlink(@sqlite), scalar(@sqlite), 'unlinked SQLite indices');
my @shards = glob("$tmpdir/xap*/?");
is(scalar(@shards), 0, 'no Xapian shards to drop');

my $rdr = { 2 => \(my $err = '') };
ok(run_script([qw(-index -Lbasic), $tmpdir], undef, $rdr), '-indexed');
my @n = $ibx->over->dbh->selectrow_array('SELECT COUNT(*) FROM over');
is_deeply(\@n, [ 3 ], 'identical message not re-indexed');
my $mm = $ibx->mm->{dbh}->selectall_arrayref(<<'');
SELECT num,mid FROM msgmap ORDER BY num ASC

is_deeply($mm, [
	[ 1, 'qp@example.com' ],
	[ 2, 'multipart-html-sucks@11' ],
	[ 3, '199707281508.AAA24167@hoyogw.example' ]
], 'msgmap omits redundant message');

done_testing;
