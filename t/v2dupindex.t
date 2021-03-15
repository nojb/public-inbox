#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# we can index a message from a mirror which bypasses dedupe.
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Import;
use PublicInbox::Git;
require_git(2.6);
require_mods(qw(DBD::SQLite));
my ($tmpdir, $for_destroy) = tmpdir();
my $inboxdir = "$tmpdir/test";
my $ibx = create_inbox('test', indexlevel => 'basic', version => 2,
		tmpdir => $inboxdir, sub {
	my ($im, $ibx) = @_;
	$im->add(eml_load('t/plack-qp.eml'));
	$im->add(eml_load('t/mda-mime.eml'));
	$im->done;

	# bypass duplicate filters (->header_set is optional)
	my $git0 = PublicInbox::Git->new("$ibx->{inboxdir}/git/0.git");
	$_[0] = undef;
	$im = PublicInbox::Import->new($git0, undef, undef, $ibx);
	$im->{path_type} = 'v2';
	$im->{lock_path} = undef;

	my $eml = eml_load('t/plack-qp.eml');
	$eml->header_set('X-This-Is-Not-Checked-By-ContentHash', 'blah');
	$im->add($eml) or BAIL_OUT 'add seen message directly';
	$im->add(eml_load('t/mda-mime.eml')) or
		BAIL_OUT 'add another seen message directly';
	$im->add(eml_load('t/iso-2202-jp.eml')) or
		BAIL_OUT 'add another new message';
	$im->done;
	# mimic a fresh clone by dropping indices
	my $dir = $ibx->{inboxdir};
	my @sqlite = (glob("$dir/*sqlite3*"), glob("$dir/xap*/*sqlite3*"));
	unlink(@sqlite) == scalar(@sqlite) or
			BAIL_OUT 'did not unlink SQLite indices';
	my @shards = glob("$dir/xap*/?");
	scalar(@shards) == 0 or BAIL_OUT 'Xapian shards created unexpectedly';
	open my $fh, '>', "$dir/empty" or BAIL_OUT;
	rmdir($_) for glob("$dir/xap*");
});
my $env = { PI_CONFIG => "$inboxdir/empty" };
my $rdr = { 2 => \(my $err = '') };
ok(run_script([qw(-index -Lbasic), $inboxdir ], $env, $rdr), '-indexed');
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
