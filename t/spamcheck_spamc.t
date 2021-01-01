# Copyright (C) 2016-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Eml;
use IO::File;
use Fcntl qw(:DEFAULT SEEK_SET);
use PublicInbox::TestCommon;
my ($tmpdir, $for_destroy) = tmpdir();

use_ok 'PublicInbox::Spamcheck::Spamc';
my $spamc = PublicInbox::Spamcheck::Spamc->new;
$spamc->{checkcmd} = [qw(cat)];

{
	open my $fh, '+>', "$tmpdir/file" or die "open failed: $!";
	ok(!$spamc->spamcheck($fh), 'empty '.ref($fh));
}
ok(!$spamc->spamcheck(IO::File->new_tmpfile), 'IO::File->new_tmpfile');

my $dst = '';
my $src = <<'EOF';
Date: Thu, 01 Jan 1970 00:00:00 +0000
To: <e@example.com>
From: <e@example.com>
Subject: test
Message-ID: <testmessage@example.com>

EOF
ok($spamc->spamcheck(PublicInbox::Eml->new($src), \$dst), 'PublicInbox::Eml works');
is($dst, $src, 'input == output');

$dst = '';
$spamc->{checkcmd} = ['sh', '-c', 'cat; false'];
ok(!$spamc->spamcheck(PublicInbox::Eml->new($src), \$dst), 'Failed check works');
is($dst, $src, 'input == output for spammy example');

for my $l (qw(ham spam)) {
	my $file = "$tmpdir/$l.out";
	$spamc->{$l.'cmd'} = ['tee', $file ];
	my $method = $l.'learn';
	ok($spamc->$method(PublicInbox::Eml->new($src)), "$method OK");
	open my $fh, '<', $file or die "failed to open $file: $!";
	is(eval { local $/, <$fh> }, $src, "$l command ran alright");
}

done_testing();
