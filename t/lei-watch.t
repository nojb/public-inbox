#!perl -w
# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Path qw(make_path remove_tree);
plan skip_all => "TEST_FLAKY not enabled for $0" if !$ENV{TEST_FLAKY};
require_mods('lei');
my $have_fast_inotify = eval { require Linux::Inotify2 } ||
	eval { require IO::KQueue };

$have_fast_inotify or
	diag("$0 IO::KQueue or Linux::Inotify2 missing, test will be slow");

my ($ro_home, $cfg_path) = setup_public_inboxes;
test_lei(sub {
	my $md = "$ENV{HOME}/md";
	my $cfg_f = "$ENV{HOME}/.config/lei/config";
	my $md2 = $md.'2';
	lei_ok 'ls-watch';
	is($lei_out, '', 'nothing in ls-watch, yet');

	my ($ino_fdinfo, $ino_contents);
	SKIP: {
		$have_fast_inotify && $^O eq 'linux' or
			skip 'Linux/inotify-only internals check', 1;
		lei_ok 'daemon-pid'; chomp(my $pid = $lei_out);
		skip 'missing /proc/$PID/fd', 1 if !-d "/proc/$pid/fd";
		my @ino = grep {
			(readlink($_) // '') =~ /\binotify\b/
		} glob("/proc/$pid/fd/*");
		is(scalar(@ino), 1, 'only one inotify FD');
		my $ino_fd = (split('/', $ino[0]))[-1];
		$ino_fdinfo = "/proc/$pid/fdinfo/$ino_fd";
		open my $fh, '<', $ino_fdinfo or xbail "open $ino_fdinfo: $!";
		$ino_contents = [ <$fh> ];
	}

	if (0) { # TODO
		my $url = 'imaps://example.com/foo.bar.0';
		lei_ok([qw(add-watch --state=pause), $url], undef, {});
		lei_ok 'ls-watch';
		is($lei_out, "$url\n", 'ls-watch shows added watch');
		ok(!lei(qw(add-watch --state=pause), 'bogus'.$url),
			'bogus URL rejected');
	}

	# first, make sure tag-ro works
	make_path("$md/new", "$md/cur", "$md/tmp");
	lei_ok qw(add-watch --state=tag-ro), $md;
	lei_ok 'ls-watch';
	like($lei_out, qr/^\Qmaildir:$md\E$/sm, 'maildir shown');
	lei_ok qw(q mid:testmessage@example.com -o), $md, '-I', "$ro_home/t1";
	my @f = glob("$md/cur/*:2,");
	is(scalar(@f), 1, 'got populated maildir with one result');
	rename($f[0], "$f[0]S") or xbail "rename $!"; # set (S)een
	tick($have_fast_inotify ? 0.2 : 2.2); # always needed for 1 CPU systems
	lei_ok qw(note-event done); # flushes immediately (instead of 5s)

	lei_ok qw(q mid:testmessage@example.com -o), $md2, '-I', "$ro_home/t1";
	my @f2 = glob("$md2/*/*");
	is(scalar(@f2), 1, 'got one result');
	like($f2[0], qr/S\z/, 'seen set from rename') or diag explain(\@f2);
	my $e2 = eml_load($f2[0]);
	my $e1 = eml_load("$f[0]S");
	is_deeply($e2, $e1, 'results match');

	SKIP: {
		$ino_fdinfo or skip 'Linux/inotify-only watch check', 1;
		open my $fh, '<', $ino_fdinfo or xbail "open $ino_fdinfo: $!";
		my $cmp = [ <$fh> ];
		ok(scalar(@$cmp) > scalar(@$ino_contents),
			'inotify has Maildir watches');
	}

	lei_ok 'rm-watch', $md;
	lei_ok 'ls-watch', \'refresh watches';
	is($lei_out, '', 'no watches left');

	lei_ok 'add-watch', $md2;
	remove_tree($md2);
	lei_ok 'rm-watch', "maildir:".$md2, \'with maildir: prefix';
	lei_ok 'ls-watch', \'refresh watches';
	is($lei_out, '', 'no watches left');

	lei_ok 'add-watch', $md;
	remove_tree($md);
	lei_ok 'rm-watch', $md, \'absolute path w/ missing dir';
	lei_ok 'ls-watch', \'refresh watches';
	is($lei_out, '', 'no watches left');

	SKIP: {
		$ino_fdinfo or skip 'Linux/inotify-only removal removal', 1;
		open my $fh, '<', $ino_fdinfo or xbail "open $ino_fdinfo: $!";
		my $cmp = [ <$fh> ];
		is_xdeeply($cmp, $ino_contents, 'inotify Maildir watches gone');
	};
});

done_testing;
