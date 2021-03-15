#!perl -w
# Copyright (C) 2014-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::Feed;
use PublicInbox::Inbox;
my $have_xml_treepp = eval { require XML::TreePP; 1 };
my ($tmpdir, $for_destroy) = tmpdir();

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

my $git_dir = "$tmpdir/gittest";
my $ibx = create_inbox 'v1', tmpdir => $git_dir, sub {
	my ($im, $ibx) = @_;
	foreach my $i (1..6) {
		$im->add(PublicInbox::Eml->new(<<EOF)) or BAIL_OUT;
From: ME <me\@example.com>
To: U <u\@example.com>
Message-Id: <$i\@example.com>
Subject: zzz #$i
Date: Thu, 01 Jan 1970 00:00:00 +0000

> drop me

msg $i

> inline me here
> this is a short quote

keep me
EOF
	}
};

$ibx->{url} = [ 'http://example.com/test' ];
$ibx->{feedmax} = 3;
my $im = $ibx->importer(0);

# spam check
{
	# check initial feed
	{
		my $feed = string_feed({ ibx => $ibx });
		SKIP: {
			skip 'XML::TreePP missing', 3 unless $have_xml_treepp;
			my $t = XML::TreePP->new->parse($feed);
			like($t->{feed}->{-xmlns}, qr/\bAtom\b/,
				'looks like an an Atom feed');
			is(scalar @{$t->{feed}->{entry}}, 3,
				'parsed three entries');
			is($t->{feed}->{id}, 'mailto:v1@example.com',
				'id is set to default');
		}

		like($feed, qr/drop me/, "long quoted text kept");
		like($feed, qr/inline me here/, "short quoted text kept");
		like($feed, qr/keep me/, "unquoted text saved");
	}

	# add a new spam message
	my $spam;
	{
		$spam = PublicInbox::Eml->new(<<EOF);
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
		my $spammy_feed = string_feed({ ibx => $ibx });
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
		my $feed = string_feed({ ibx => $ibx });
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

done_testing;
