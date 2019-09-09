# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;

use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Git';
my $tmpdir = tempdir('pi-nulsubject-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/a.git";

{
	is(system(qw(git init -q --bare), $git_dir), 0, 'git init ok');
	my $git = PublicInbox::Git->new($git_dir);
	my $im = PublicInbox::Import->new($git, 'testbox', 'test@example');
	$im->add(Email::MIME->create(
		header => [
			From => 'a@example.com',
			To => 'b@example.com',
			'Content-Type' => 'text/plain',
			Subject => ' A subject line with a null =?iso-8859-1?q?=00?= see!',
			'Message-ID' => '<null-test.a@example.com>',
		],
		body => "hello world\n",
	));
	$im->done;
	is(system(qw(git --git-dir), $git_dir, 'fsck', '--strict'), 0, 'git fsck ok');
}

done_testing();

1;
