# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use Email::Simple;
use PublicInbox::Feed;
use PublicInbox::Config;
use IPC::Run qw/run/;
use File::Temp qw/tempdir/;
my $have_xml_feed = eval { require XML::Feed; 1 };
require 't/common.perl';

sub string_feed {
	stream_to_string(PublicInbox::Feed::generate($_[0]));
}

my $tmpdir = tempdir(CLEANUP => 1);
my $git_dir = "$tmpdir/gittest";

{
	is(0, system(qw(git init -q --bare), $git_dir), "git init");
	local $ENV{GIT_DIR} = $git_dir;

	foreach my $i (1..6) {
		my $simple = Email::Simple->new(<<EOF);
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
		my $str = $simple->as_string;
		run(['ssoma-mda', $git_dir], \$str) or
			die "mda failed: $?\n";
	}
}

# spam check
{
	# check initial feed
	{
		my $feed = string_feed({
			git_dir => $git_dir,
			max => 3
		});
		SKIP: {
			skip 'XML::Feed missing', 2 unless $have_xml_feed;
			my $p = XML::Feed->parse(\$feed);
			is($p->format, "Atom", "parsed atom feed");
			is(scalar $p->entries, 3, "parsed three entries");
			is($p->id, 'mailto:public-inbox@example.com',
				"id is set to default");
		}

		unlike($feed, qr/drop me/, "long quoted text dropped");
		like($feed, qr!/f/\d%40example\.com\.html\b!,
			"/f/ url generated for long quoted text");
		like($feed, qr/inline me here/, "short quoted text kept");
		like($feed, qr/keep me/, "unquoted text saved");
	}

	# add a new spam message
	my $spam;
	{
		my $pid = open(my $pipe, "|-");
		defined $pid or die "fork/pipe failed: $!\n";
		if ($pid == 0) {
			exec("ssoma-mda", $git_dir);
		}

		$spam = Email::Simple->new(<<EOF);
From: SPAMMER <spammer\@example.com>
To: U <u\@example.com>
Message-Id: <this-is-spam\@example.com>
Subject: SPAM!!!!!!!!
Date: Thu, 01 Jan 1970 00:00:00 +0000

EOF
		print $pipe $spam->as_string or die "print failed: $!\n";
		close $pipe or die "close pipe failed: $!\n";
	}

	# check spam shows up
	{
		my $spammy_feed = string_feed({
			git_dir => $git_dir,
			max => 3
		});
		SKIP: {
			skip 'XML::Feed missing', 2 unless $have_xml_feed;
			my $p = XML::Feed->parse(\$spammy_feed);
			is($p->format, "Atom", "parsed atom feed");
			is(scalar $p->entries, 3, "parsed three entries");
		}
		like($spammy_feed, qr/SPAM/s, "spam showed up :<");
	}

	# nuke spam
	{
		my $spam_str = $spam->as_string;
		run(["ssoma-rm", $git_dir], \$spam_str) or
				die "ssoma-rm failed: $?\n";
	}

	# spam no longer shows up
	{
		my $feed = string_feed({
			git_dir => $git_dir,
			max => 3
		});
		SKIP: {
			skip 'XML::Feed missing', 2 unless $have_xml_feed;
			my $p = XML::Feed->parse(\$feed);
			is($p->format, "Atom", "parsed atom feed");
			is(scalar $p->entries, 3, "parsed three entries");
		}
		unlike($feed, qr/SPAM/, "spam gone :>");
	}
}

# check pi_config
{
	foreach my $addr (('a@example.com'), ['a@example.com','b@localhost']) {
		my $feed = string_feed({
			git_dir => $git_dir,
			max => 3,
			listname => 'asdf',
			pi_config => bless({
				'publicinbox.asdf.address' => $addr,
			}, 'PublicInbox::Config'),
		});
		SKIP: {
			skip 'XML::Feed missing', 3 unless $have_xml_feed;
			my $p = XML::Feed->parse(\$feed);
			is($p->id, 'mailto:a@example.com',
				"ID is set correctly");
			is($p->format, "Atom", "parsed atom feed");
			is(scalar $p->entries, 3, "parsed three entries");
		}
	}
}

done_testing();
