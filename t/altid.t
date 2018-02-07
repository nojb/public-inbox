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

{
	my $mm = PublicInbox::Msgmap->new_file($alt_file, 1);
	$mm->mid_set(1234, 'a@example.com');
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
	my $inbox = PublicInbox::Inbox->new({mainrepo=>$git_dir});
	$inbox->{altid} = $altid;
	my $rw = PublicInbox::SearchIdx->new($inbox, 1);
	$rw->index_sync;
}

{
	my $ro = PublicInbox::Search->new($git_dir, $altid);
	my $res = $ro->query("gmane:1234");
	is($res->{total}, 1, 'got one match');
	is($res->{msgs}->[0]->mid, 'a@example.com');

	$res = $ro->query("gmane:666");
	is($res->{total}, 0, 'body did NOT match');
};

done_testing();

1;
