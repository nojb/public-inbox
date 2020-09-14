# Copyright (C) 2019-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
require_mods(qw(DBD::SQLite Search::Xapian));
require_git('2.6');
use PublicInbox::Eml;
use PublicInbox::InboxWritable;
require PublicInbox::Search;

my $mime = PublicInbox::Eml->new(<<'EOF');
From: a@example.com
To: test@example.com
Subject: this is a subject
Date: Fri, 02 Oct 1993 00:00:00 +0000

EOF
my ($this) = (split('/', $0))[-1];
my ($tmpdir, $for_destroy) = tmpdir();
local $ENV{PI_CONFIG} = "$tmpdir/config";
my $ibx = PublicInbox::Inbox->new({
	inboxdir => "$tmpdir/testbox",
	name => $this,
	version => 2,
	-primary_address => 'test@example.com',
	indexlevel => 'medium',
});
my @xcpdb = qw(-xcpdb -q);
my $nproc = 8;
my $ndoc = 13;
my $im = PublicInbox::InboxWritable->new($ibx, {nproc => $nproc})->importer;
for my $i (1..$ndoc) {
	$mime->header_set('Message-ID', "<m$i\@example.com>");
	ok($im->add($mime), "message $i added");
}
$im->done;
my @shards = grep(m!/\d+\z!, glob("$ibx->{inboxdir}/xap*/*"));
is(scalar(@shards), $nproc - 1, 'got expected shards');
my $orig = $ibx->over->query_xover(1, $ndoc);
my %nums = map {; "$_->{num}" => 1 } @$orig;

# ensure we can go up or down in shards, or stay the same:
for my $R (qw(2 4 1 3 3)) {
	delete $ibx->{search}; # release old handles
	my $cmd = [@xcpdb, "-R$R", $ibx->{inboxdir}];
	push @$cmd, '--compact' if $R == 1 && have_xapian_compact;
	ok(run_script($cmd), "xcpdb -R$R");
	my @new_shards = grep(m!/\d+\z!, glob("$ibx->{inboxdir}/xap*/*"));
	is(scalar(@new_shards), $R, 'resharded to two shards');
	my $mset = $ibx->search->mset('s:this');
	my $msgs = $ibx->search->mset_to_smsg($ibx, $mset);
	is(scalar(@$msgs), $ndoc, 'got expected docs after resharding');
	my %by_mid = map {; "$_->{mid}" => $_ } @$msgs;
	ok($by_mid{"m$_\@example.com"}, "$_ exists") for (1..$ndoc);

	delete $ibx->{search}; # release old handles

	# ensure docids in Xapian match NNTP article numbers
	my $tot = 0;
	my %tmp = %nums;
	my $XapianDatabase = do {
		no warnings 'once';
		$PublicInbox::Search::X{Database};
	};
	foreach my $d (@new_shards) {
		my $xdb = $XapianDatabase->new($d);
		$tot += $xdb->get_doccount;
		my $it = $xdb->postlist_begin('');
		my $end = $xdb->postlist_end('');
		for (; $it != $end; $it++) {
			my $docid = $it->get_docid;
			if ($xdb->get_document($docid)) {
				ok(delete($tmp{$docid}), "saw #$docid");
			}
		}
	}
	is(scalar keys %tmp, 0, 'all docids seen');
}

done_testing();
1;
