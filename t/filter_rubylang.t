# Copyright (C) 2017-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
use PublicInbox::TestCommon;
use_ok 'PublicInbox::Filter::RubyLang';

my $f = PublicInbox::Filter::RubyLang->new;
ok($f, 'created PublicInbox::Filter::RubyLang object');
my $msg = <<'EOF';
Subject: test

keep this

Unsubscribe: <mailto:ruby-core-request@ruby-lang.org?subject=unsubscribe>
<http://lists.ruby-lang.org/cgi-bin/mailman/options/ruby-core>
EOF
my $mime = PublicInbox::Eml->new($msg);
my $ret = $f->delivery($mime);
is($ret, $mime, "delivery successful");
is($mime->body, "keep this\n", 'normal message filtered OK');

SKIP: {
	require_mods('DBD::SQLite', 4);
	use_ok 'PublicInbox::Inbox';
	my ($git_dir, $for_destroy) = tmpdir();
	is(mkdir("$git_dir/public-inbox"), 1, "created public-inbox dir");
	my $altid = [
		# 'serial:ruby-core:file=msgmap.sqlite3' can be used here
		# for documentation purposes, but Xapian ignores everything
		# up to and including the '-'
		'serial:core:file=msgmap.sqlite3'
	];
	my $ibx = PublicInbox::Inbox->new({ inboxdir => $git_dir,
						altid => $altid });
	$f = PublicInbox::Filter::RubyLang->new(ibx => $ibx);
	$msg = <<'EOF';
X-Mail-Count: 12
Message-ID: <a@b>

EOF
	$mime = PublicInbox::Eml->new($msg);
	$ret = $f->delivery($mime);
	is($ret, $mime, "delivery successful");
	my $mm = $ibx->mm;
	is($mm->num_for('a@b'), 12, 'MM entry created based on X-ML-Count');

	$msg = <<'EOF';
X-Mail-Cout: 12
Message-ID: <b@b>

EOF

	$mime = PublicInbox::Eml->new($msg);
	$ret = $f->delivery($mime);
	is($ret, 100, "delivery rejected without X-Mail-Count");
}

done_testing();
