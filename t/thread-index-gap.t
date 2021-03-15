#!perl -w
# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
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
for my $msgs (['orig', reverse @msgs], ['shuffle', shuffle(@msgs)]) {
	my $desc = shift @$msgs;
	my $n = "index-cap-$desc";
	# yes, the shuffle case gets memoized by create_inbox, oh well
	my $ibx = create_inbox $desc, version => 2, indexlevel => 'full',
				tmpdir => "$home/$desc", sub {
		my ($im) = @_;
		for my $m (@$msgs) {
			my $x = "$m\nFrom: x\@example.com\n\n";
			$im->add(PublicInbox::Eml->new(\$x));
		}
	};
	my $over = $ibx->over;
	my $dbh = $over->dbh;
	my $tid = $dbh->selectall_arrayref('SELECT DISTINCT(tid) FROM over');
	is(scalar(@$tid), 1, "only one thread initially ($desc)");
	$over->dbh_close;
	my $env = { HOME => $home };
	run_script([qw(-index --no-fsync --reindex --rethread),
			$ibx->{inboxdir}], $env) or BAIL_OUT 'rethread';
	$tid = $dbh->selectall_arrayref('SELECT DISTINCT(tid) FROM over');
	is(scalar(@$tid), 1, "only one thread after rethread ($desc)");
}

done_testing;
