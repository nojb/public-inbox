# Copyright (C) 2017-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use bytes (); # only for bytes::length
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::MID qw(mids);
use PublicInbox::Eml;
require_mods(qw(DBD::SQLite Search::Xapian));
require PublicInbox::SearchIdx;
require PublicInbox::Smsg;
require PublicInbox::Inbox;
use PublicInbox::Import;
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";

PublicInbox::Import::init_bare($git_dir);
my $ibx = PublicInbox::Inbox->new({inboxdir => $git_dir});
my $rw = PublicInbox::SearchIdx->new($ibx, 1);
ok($rw, "search indexer created");
my $data = <<'EOF';
Subject: [RFC 00/14]
Message-Id: <1-bw@g>

Subject: [RFC 09/14]
Message-Id: <10-bw@g>
In-Reply-To: <1-bw@g>
References: <1-bw@g>

Subject: [RFC 03/14]
Message-Id: <4-bw@g>
In-Reply-To: <1-bw@g>
References: <1-bw@g>

EOF

my $num = 0;
# nb. using internal API, fragile!
my $xdb = $rw->begin_txn_lazy;
my @mids;

foreach (reverse split(/\n\n/, $data)) {
	$_ .= "\n";
	my $mime = PublicInbox::Eml->new(\$_);
	$mime->header_set('From' => 'bw@g');
	$mime->header_set('To' => 'git@vger.kernel.org');
	my $bytes = bytes::length($mime->as_string);
	my $mid = mids($mime->header_obj)->[0];
	my $smsg = bless {
		bytes => $bytes,
		num => ++$num,
		mid => $mid,
		blob => '',
	}, 'PublicInbox::Smsg';
	my $doc_id = $rw->add_message($mime, $smsg);
	push @mids, $mid;
	ok($doc_id, 'message added: '. $mid);
}

my $prev;
my %tids;
my $dbh = $rw->{oidx}->dbh;
foreach my $mid (@mids) {
	my $msgs = $rw->{oidx}->get_thread($mid);
	is(3, scalar(@$msgs), "got all messages from $mid");
	foreach my $m (@$msgs) {
		my $tid = $dbh->selectrow_array(<<'', undef, $m->{num});
SELECT tid FROM over WHERE num = ? LIMIT 1

		$tids{$tid}++;
	}
}

is(scalar keys %tids, 1, 'all messages have the same tid');

$rw->commit_txn_lazy;

$xdb = $rw->begin_txn_lazy;
{
	my $mime = PublicInbox::Eml->new(<<'');
Subject: [RFC 00/14]
Message-Id: <1-bw@g>
From: bw@g
To: git@vger.kernel.org

	my $dbh = $rw->{oidx}->dbh;
	my ($id, $prev);
	my $reidx = $rw->{oidx}->next_by_mid('1-bw@g', \$id, \$prev);
	ok(defined $reidx);
	my $num = $reidx->{num};
	my $tid0 = $dbh->selectrow_array(<<'', undef, $num);
SELECT tid FROM over WHERE num = ? LIMIT 1

	my $bytes = bytes::length($mime->as_string);
	my $mid = mids($mime->header_obj)->[0];
	my $smsg = bless {
		bytes => $bytes,
		num => $num,
		mid => $mid,
		blob => '',
	}, 'PublicInbox::Smsg';
	my $doc_id = $rw->add_message($mime, $smsg);
	ok($doc_id, 'message reindexed'. $mid);
	is($doc_id, $num, "article number unchanged: $num");

	my $tid1 = $dbh->selectrow_array(<<'', undef, $num);
SELECT tid FROM over WHERE num = ? LIMIT 1

	is($tid1, $tid0, 'tid unchanged on reindex');
}

$rw->commit_txn_lazy;

done_testing();

1;
