#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use PublicInbox::InboxWritable;
use PublicInbox::Config;
use List::Util qw(shuffle);
require_mods(qw(DBD::SQLite));
require_git(2.6);

chomp(my @msgs = split(/\n\n/, <<'EOF')); # "git log" order
Subject: [bug#45000] [PATCH 1/9]
References: <20201202045335.31096-1-j@example.com>
Message-Id: <20201202045540.31248-1-j@example.com>

Subject: [bug#45000] [PATCH 0/9]
Message-Id: <20201202045335.31096-1-j@example.com>

Subject: [bug#45000] [PATCH 0/9]
References: <20201202045335.31096-1-j@example.com>
Message-ID: <86sg8o1mou.fsf@example.com>

Subject: [bug#45000] [PATCH 8/9]
Message-Id: <20201202045540.31248-8-j@example.com>
References: <20201202045540.31248-1-j@example.com>

EOF

my ($home, $for_destroy) = tmpdir();
local $ENV{HOME} = $home;
for my $msgs (['orig', reverse @msgs], ['shuffle', shuffle(@msgs)]) {
	my $desc = shift @$msgs;
	my $n = "index-cap-$desc";
	run_script([qw(-init -L basic -V2), $n, "$home/$n",
		"http://example.com/$n", "$n\@example.com"]) or
		BAIL_OUT 'init';
	my $ibx = PublicInbox::Config->new->lookup_name($n);
	my $im = PublicInbox::InboxWritable->new($ibx)->importer(0);
	for my $m (@$msgs) {
		$im->add(PublicInbox::Eml->new("$m\nFrom: x\@example.com\n\n"));
	}
	$im->done;
	my $over = $ibx->over;
	my $dbh = $over->dbh;
	my $tid = $dbh->selectall_arrayref('SELECT DISTINCT(tid) FROM over');
	my @tid = map { $_->[0] } @$tid;
	is(scalar(@tid), 1, "only one thread initially ($desc)");
	$over->dbh_close;
	run_script([qw(-index --reindex --rethread), $ibx->{inboxdir}]) or
		BAIL_OUT 'rethread';
	$tid = $dbh->selectall_arrayref('SELECT DISTINCT(tid) FROM over');
	@tid = map { $_->[0] } @$tid;
	is(scalar(@tid), 1, "only one thread after rethread ($desc)");
}

done_testing;
