# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::TestCommon;
require_git(2.6);
require_mods(qw(DBD::SQLite));
use Cwd qw(abs_path); # we need this since we chdir below
local $ENV{HOME} = abs_path('t');
my $purge = abs_path('blib/script/public-inbox-purge');
my ($tmpdir, $for_destroy) = tmpdir();
use_ok 'PublicInbox::V2Writable';
my $inboxdir = "$tmpdir/v2";
my $ibx = PublicInbox::Inbox->new({
	inboxdir => $inboxdir,
	name => 'test-v2purge',
	version => 2,
	-primary_address => 'test@example.com',
	indexlevel => 'basic',
});

my $raw = <<'EOF';
From: a@example.com
To: test@example.com
Subject: this is a subject
Message-ID: <a-mid@b>
Date: Fri, 02 Oct 1993 00:00:00 +0000

Hello World

EOF

my $cfgfile = "$tmpdir/config";
local $ENV{PI_CONFIG} = $cfgfile;
open my $cfg_fh, '>', $cfgfile or die "open: $!";

my $v2w = PublicInbox::V2Writable->new($ibx, {nproc => 1});
my $mime = PublicInbox::Eml->new($raw);
ok($v2w->add($mime), 'add message to be purged');
$v2w->done;

# failing cases, first:
my $in = "$raw\nMOAR\n";
my ($out, $err) = ('', '');
my $opt = { 0 => \$in, 1 => \$out, 2 => \$err };
ok(run_script([$purge, '-f', $inboxdir], undef, $opt), 'purge -f OK');

$out = $err = '';
ok(!run_script([$purge, $inboxdir], undef, $opt), 'mismatch fails without -f');
is($? >> 8, 1, 'missed purge exits with 1');

# a successful case:
$opt->{0} = \$raw;
ok(run_script([$purge, $inboxdir], undef, $opt), 'match OK');
like($out, qr/\b[a-f0-9]{40,}/m, 'removed commit noted');

# add (old) vger filter to config file
print $cfg_fh <<EOF or die "print $!";
[publicinbox "test-v2purge"]
	inboxdir = $inboxdir
	address = test\@example.com
	indexlevel = basic
	filter = PublicInbox::Filter::Vger
EOF
close $cfg_fh or die "close: $!";

ok($v2w->add($mime), 'add vger-signatured message to be purged');
$v2w->done;

my $pre_scrub = $raw . <<'EOF';

--
To unsubscribe from this list: send the line "unsubscribe linux-kernel" in
the body of a message to majordomo@vger.kernel.org
More majordomo info at  http://vger.kernel.org/majordomo-info.html
Please read the FAQ at  http://www.tux.org/lkml/
EOF

$out = $err = '';
ok(chdir('/'), "chdir / OK for --all test");
$opt->{0} = \$pre_scrub;
ok(run_script([$purge, '--all'], undef, $opt), 'scrub purge OK');
like($out, qr/\b[a-f0-9]{40,}/m, 'removed commit noted');
# diag "out: $out"; diag "err: $err";

$out = $err = '';
ok(!run_script([$purge, '--all' ], undef, $opt),
	'scrub purge not idempotent without -f');
# diag "out: $out"; diag "err: $err";

done_testing();
