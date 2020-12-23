#!perl -w
# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use Test::More;
use PublicInbox::TestCommon;
use PublicInbox::Eml;
use File::Path qw(mkpath);
use IO::Handle (); # autoflush
use POSIX qw(_exit);
use Cwd qw(getcwd abs_path);
use File::Spec;
my $many_root = $ENV{TEST_MANY_ROOT} or
	plan skip_all => 'TEST_MANY_ROOT not defined';
my $cwd = getcwd();
mkpath($many_root);
-d $many_root or BAIL_OUT "$many_root: $!";
$many_root = abs_path($many_root);
$many_root =~ m!\A\Q$cwd\E/! and BAIL_OUT "$many_root must not be in $cwd";
require_git 2.6;
require_mods(qw(DBD::SQLite Search::Xapian));
use_ok 'PublicInbox::V2Writable';
my $nr_inbox = $ENV{NR_INBOX} // 10;
my $nproc = $ENV{NPROC} || PublicInbox::V2Writable::detect_nproc() || 2;
my $indexlevel = $ENV{TEST_INDEXLEVEL} // 'basic';
diag "NR_INBOX=$nr_inbox NPROC=$nproc TEST_INDEXLEVEL=$indexlevel";
diag "TEST_MANY_ROOT=$many_root";
my $level_cfg = $indexlevel eq 'full' ? '' : "\tindexlevel = $indexlevel\n";
my $pfx = "$many_root/$nr_inbox-$indexlevel";
mkpath($pfx);
open my $cfg_fh, '>>', "$pfx/config" or BAIL_OUT $!;
$cfg_fh->autoflush(1);
my $v2_init_add = sub {
	my ($i) = @_;
	my $ibx = PublicInbox::Inbox->new({
		inboxdir => "$pfx/test-$i",
		name => "test-$i",
		newsgroup => "inbox.comp.test.foo.test-$i",
		address => [ "test-$i\@example.com" ],
		url => [ "//example.com/test-$i" ],
		version => 2,
	});
	$ibx->{indexlevel} = $indexlevel if $level_cfg ne '';
	my $entry = <<EOF;
[publicinbox "$ibx->{name}"]
	address = $ibx->{-primary_address}
	url = $ibx->{url}->[0]
	newsgroup = $ibx->{newsgroup}
	inboxdir = $ibx->{inboxdir}
EOF
	$entry .= $level_cfg;
	print $cfg_fh $entry or die $!;
	my $v2w = PublicInbox::V2Writable->new($ibx, { nproc => 0 });
	$v2w->init_inbox(0);
	$v2w->add(PublicInbox::Eml->new(<<EOM));
Date: Sat, 02 Oct 2010 00:00:00 +0000
From: Lorelei <l\@example.com>
To: test-$i\@example.com
Message-ID: <20101002-000000-$i\@example.com>
Subject: hello world $i

hi
EOM
	$v2w->done;
};

my @children;
for my $i (1..$nproc) {
	my ($r, $w);
	pipe($r, $w) or BAIL_OUT $!;
	my $pid = fork;
	if ($pid == 0) {
		close $w;
		while (my $i = <$r>) {
			chomp $i;
			$v2_init_add->($i);
		}
		_exit(0);
	}
	defined $pid or BAIL_OUT "fork: $!";
	close $r or BAIL_OUT $!;
	push @children, [ $w, $pid ];
	$w->autoflush(1);
}

for my $i (0..$nr_inbox) {
	print { $children[$i % @children]->[0] } "$i\n" or BAIL_OUT $!;
}

for my $c (@children) {
	close $c->[0] or BAIL_OUT "close $!";
}
my $i = 0;
for my $c (@children) {
	my $pid = waitpid($c->[1], 0);
	is($?, 0, ++$i.' exited ok');
}
ok(close($cfg_fh), 'config written');
done_testing;
