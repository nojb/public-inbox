# Copyright (C) 2017-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use Email::MIME;
eval { require PublicInbox::SearchIdx; };
plan skip_all => "Xapian missing for search" if $@;
my $tmpdir = tempdir('pi-search-thr-index.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $git_dir = "$tmpdir/a.git";

is(0, system(qw(git init -q --bare), $git_dir), "git init (main)");
my $rw = PublicInbox::SearchIdx->new($git_dir, 1);
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
my $xdb = $rw->_xdb_acquire;
$xdb->begin_transaction;
my @mids;

foreach (reverse split(/\n\n/, $data)) {
	$_ .= "\n";
	my $mime = Email::MIME->new(\$_);
	$mime->header_set('From' => 'bw@g');
	$mime->header_set('To' => 'git@vger.kernel.org');
	my $bytes = bytes::length($mime->as_string);
	my $doc_id = $rw->add_message($mime, $bytes, ++$num, 'ignored');
	my $mid = $mime->header('Message-Id');
	push @mids, $mid;
	ok($doc_id, 'message added: '. $mid);
}

my $prev;
foreach my $mid (@mids) {
	my $res = $rw->get_thread($mid);
	is(3, $res->{total}, "got all messages from $mid");
}

done_testing();

1;
