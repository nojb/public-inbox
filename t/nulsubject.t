# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;

use_ok 'PublicInbox::Import';
use_ok 'PublicInbox::Git';
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";

{
	my $git = PublicInbox::Git->new($git_dir);
	my $im = PublicInbox::Import->new($git, 'testbox', 'test@example');
	$im->init_bare;
	$im->add(PublicInbox::Eml->new(<<'EOF'));
From: a@example.com
To: b@example.com
Subject: A subject line with a null =?iso-8859-1?q?=00?= see!
Message-ID: <null-test.a@example.com>

hello world
EOF
	$im->done;
	is(xsys(qw(git --git-dir), $git_dir, 'fsck', '--strict'), 0,
		'git fsck ok');
}

done_testing();

1;
