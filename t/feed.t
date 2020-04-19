# Copyright (C) 2014-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use PublicInbox::Feed;
use PublicInbox::Import;
use PublicInbox::Inbox;
my $have_xml_treepp = eval { require XML::TreePP; 1 };
use PublicInbox::TestCommon;

sub string_feed {
	my $res = PublicInbox::Feed::generate($_[0]);
	my $body = $res->[2];
	my $str = '';
	while (defined(my $chunk = $body->getline)) {
		$str .= $chunk;
	}
	$body->close;
	$str;
}

my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/gittest";
my $ibx = PublicInbox::Inbox->new({
	address => 'test@example',
	name => 'testbox',
	inboxdir => $git_dir,
	url => [ 'http://example.com/test' ],
	feedmax => 3,
});
my $git = $ibx->git;
my $im = PublicInbox::Import->new($git, $ibx->{name}, 'test@example');

{
	$im->init_bare;
	local $ENV{GIT_DIR} = $git_dir;

	foreach my $i (1..6) {
		my $mime = Email::MIME->new(<<EOF);
From: ME <me\@example.com>
To: U <u\@example.com>
Message-Id: <$i\@example.com>
Subject: zzz #$i
Date: Thu, 01 Jan 1970 00:00:00 +0000

> This is a long multi line quote so it should not be allowed to
> show up in its entirty in the Atom feed.  drop me
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much
> I quote to much

msg $i

> inline me here
> this is a short quote

keep me
EOF
		like($im->add($mime), qr/\A:\d+/, 'added');
	}
	$im->done;
}

# spam check
{
	# check initial feed
	{
		my $feed = string_feed({ -inbox => $ibx });
		SKIP: {
			skip 'XML::TreePP missing', 3 unless $have_xml_treepp;
			my $t = XML::TreePP->new->parse($feed);
			like($t->{feed}->{-xmlns}, qr/\bAtom\b/,
				'looks like an an Atom feed');
			is(scalar @{$t->{feed}->{entry}}, 3,
				'parsed three entries');
			is($t->{feed}->{id}, 'mailto:test@example',
				'id is set to default');
		}

		like($feed, qr/drop me/, "long quoted text kept");
		like($feed, qr/inline me here/, "short quoted text kept");
		like($feed, qr/keep me/, "unquoted text saved");
	}

	# add a new spam message
	my $spam;
	{
		$spam = Email::MIME->new(<<EOF);
From: SPAMMER <spammer\@example.com>
To: U <u\@example.com>
Message-Id: <this-is-spam\@example.com>
Subject: SPAM!!!!!!!!
Date: Thu, 01 Jan 1970 00:00:00 +0000

EOF
		$im->add($spam);
		$im->done;
	}

	# check spam shows up
	{
		my $spammy_feed = string_feed({ -inbox => $ibx });
		SKIP: {
			skip 'XML::TreePP missing', 2 unless $have_xml_treepp;
			my $t = XML::TreePP->new->parse($spammy_feed);
			like($t->{feed}->{-xmlns}, qr/\bAtom\b/,
				'looks like an an Atom feed');
			is(scalar @{$t->{feed}->{entry}}, 3,
				'parsed three entries');
		}
		like($spammy_feed, qr/SPAM/s, "spam showed up :<");
	}

	# nuke spam
	$im->remove($spam);
	$im->done;

	# spam no longer shows up
	{
		my $feed = string_feed({ -inbox => $ibx });
		SKIP: {
			skip 'XML::TreePP missing', 2 unless $have_xml_treepp;
			my $t = XML::TreePP->new->parse($feed);
			like($t->{feed}->{-xmlns}, qr/\bAtom\b/,
				'looks like an an Atom feed');
			is(scalar @{$t->{feed}->{entry}}, 3,
				'parsed three entries');
		}
		unlike($feed, qr/SPAM/, "spam gone :>");
	}
}

done_testing();
