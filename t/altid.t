# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
foreach my $mod (qw(DBD::SQLite Search::Xapian)) {
	eval "require $mod";
	plan skip_all => "$mod missing for altid.t" if $@;
}

use_ok 'PublicInbox::Msgmap';
use_ok 'PublicInbox::SearchIdx';
use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Inbox';
my $tmpdir = tempdir('pi-altid-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/a.git";
my $alt_file = "$tmpdir/another-nntp.sqlite3";
my $altid = [ "serial:gmane:file=$alt_file" ];
my $ibx;

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 1);
	is($mm->mid_set(1234, 'a@example.com'), 1, 'mid_set once OK');
	ok(0 == $mm->mid_set(1234, 'a@example.com'), 'mid_set not idempotent');
	ok(0 == $mm->mid_set(1, 'a@example.com'), 'mid_set fails with dup MID');
}

{
	is(system(qw(git init -q --bare), $git_dir), 0, 'git init ok');
	my $git = PublicInbox::Git->new($git_dir);
	my $im = PublicInbox::Import->new($git, 'testbox', 'test@example');
	$im->add(Email::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			Subject => 'boo!',
			'Message-ID' => '<a@example.com>',
		],
		body => "hello world gmane:666\n",
	));
	$im->done;
}
{
	$ibx = PublicInbox::Inbox->new({mainrepo => $git_dir});
	$ibx->{altid} = $altid;
	my $rw = PublicInbox::SearchIdx->new($ibx, 1);
	$rw->index_sync;
}

{
	my $ro = PublicInbox::Search->new($ibx);
	my $msgs = $ro->query("gmane:1234");
	is_deeply([map { $_->mid } @$msgs], ['a@example.com'], 'got one match');

	$msgs = $ro->query("gmane:666");
	is_deeply([], $msgs, 'body did NOT match');
};

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 1);
	my ($min, $max) = $mm->minmax;
	my $num = $mm->mid_insert('b@example.com');
	ok($num > $max, 'auto-increment goes beyond mid_set');
}

done_testing();

1;
