# Copyright (C) 2014-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::Feed;
use PublicInbox::Git;
use PublicInbox::Import;
use PublicInbox::Inbox;
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/gittest";
my $ibx = PublicInbox::Inbox->new({
	address => 'test@example',
	name => 'tester',
	inboxdir => $git_dir,
	url => 'http://example.com/test',
});
my $git = $ibx->git;
my $im = PublicInbox::Import->new($git, 'tester', 'test@example');

# setup
{
	$im->init_bare;
	my $prev = "";

	foreach my $i (1..6) {
		my $mid = "<$i\@example.com>";
		my $mid_line = "Message-ID: $mid";
		if ($prev) {
			$mid_line .= "In-Reply-To: $prev";
		}
		$prev = $mid;
		my $mime = Email::MIME->new(<<EOF);
From: ME <me\@example.com>
To: U <u\@example.com>
$mid_line
Subject: zzz #$i
Date: Thu, 01 Jan 1970 00:00:00 +0000

> This is a long multi line quote so it should not be allowed to
> show up in its entirty in the Atom feed.  drop me

msg $i

> inline me here, short quote

keep me
EOF
		like($im->add($mime), qr/\A:\d+\z/, 'inserted message');
	}
	$im->done;
}

done_testing();
