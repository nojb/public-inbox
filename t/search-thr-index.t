# Copyright (C) 2017-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use bytes (); # only for bytes::length
use Test::More;
use PublicInbox::MID qw(mids);
use Email::MIME;
my @mods = qw(DBI DBD::SQLite Search::Xapian);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "missing $mod for $0" if $@;
}
require PublicInbox::SearchIdx;
require PublicInbox::Inbox;
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();
my $git_dir = "$tmpdir/a.git";

is(0, system(qw(git init -q --bare), $git_dir), "git init (main)");
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
	my $mime = Email::MIME->new(\$_);
	$mime->header_set('From' => 'bw@g');
	$mime->header_set('To' => 'git@vger.kernel.org');
	my $bytes = bytes::length($mime->as_string);
	my $mid = mids($mime->header_obj)->[0];
	my $doc_id = $rw->add_message($mime, $bytes, ++$num, 'ignored', $mid);
	push @mids, $mid;
	ok($doc_id, 'message added: '. $mid);
}

my $prev;
my %tids;
my $dbh = $rw->{over}->connect;
foreach my $mid (@mids) {
	my $msgs = $rw->{over}->get_thread($mid);
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
	my $mime = Email::MIME->new(<<'');
Subject: [RFC 00/14]
Message-Id: <1-bw@g>
From: bw@g
To: git@vger.kernel.org

	my $dbh = $rw->{over}->connect;
	my ($id, $prev);
	my $reidx = $rw->{over}->next_by_mid('1-bw@g', \$id, \$prev);
	ok(defined $reidx);
	my $num = $reidx->{num};
	my $tid0 = $dbh->selectrow_array(<<'', undef, $num);
SELECT tid FROM over WHERE num = ? LIMIT 1

	my $bytes = bytes::length($mime->as_string);
	my $mid = mids($mime->header_obj)->[0];
	my $doc_id = $rw->add_message($mime, $bytes, $num, 'ignored', $mid);
	ok($doc_id, 'message reindexed'. $mid);
	is($doc_id, $num, "article number unchanged: $num");

	my $tid1 = $dbh->selectrow_array(<<'', undef, $num);
SELECT tid FROM over WHERE num = ? LIMIT 1

	is($tid1, $tid0, 'tid unchanged on reindex');
}

$rw->commit_txn_lazy;

done_testing();

1;
