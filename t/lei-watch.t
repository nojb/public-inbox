#!perl -w
# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Path qw(make_path);
require_mods('lei');
my $have_fast_inotify = eval { require Linux::Inotify2 } ||
	eval { require IO::KQueue };

$have_fast_inotify or
	diag("$0 IO::KQueue or Linux::Inotify2 missing, test will be slow");

my ($ro_home, $cfg_path) = setup_public_inboxes;
test_lei(sub {
	my $md = "$ENV{HOME}/md";
	my $md2 = $md.'2';
	lei_ok 'ls-watch';
	is($lei_out, '', 'nothing in ls-watch, yet');
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
	$have_fast_inotify or tick(2);
	lei_ok qw(note-event done); # flushes immediately (instead of 5s)

	lei_ok qw(q mid:testmessage@example.com -o), $md2, '-I', "$ro_home/t1";
	my @f2 = glob("$md2/*/*");
	is(scalar(@f2), 1, 'got one result');
	like($f2[0], qr/S\z/, 'seen set from rename');
	my $e2 = eml_load($f2[0]);
	my $e1 = eml_load("$f[0]S");
	is_deeply($e2, $e1, 'results match');
});

done_testing;
