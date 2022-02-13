#!perl -w
# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use File::Basename qw(basename);
plan skip_all => "TEST_FLAKY not enabled for $0" if !$ENV{TEST_FLAKY};
my $have_fast_inotify = eval { require Linux::Inotify2 } ||
	eval { require IO::KQueue };
$have_fast_inotify or
	diag("$0 IO::KQueue or Linux::Inotify2 missing, test will be slow");

test_lei(sub {
	my ($ro_home, $cfg_path) = setup_public_inboxes;
	my $x = "$ENV{HOME}/x";
	my $y = "$ENV{HOME}/y";
	lei_ok qw(add-external), "$ro_home/t1";
	lei_ok qw(q mid:testmessage@example.com -o), $x;
	lei_ok qw(q mid:testmessage@example.com -o), $y;
	my @x = glob("$x/cur/*");
	my @y = glob("$y/cur/*");
	scalar(@x) == 1 or xbail 'expected 1 file', \@x;
	scalar(@y) == 1 or xbail 'expected 1 file', \@y;

	my $oid = '9bf1002c49eb075df47247b74d69bcd555e23422';
	lei_ok qw(inspect), "blob:$oid";
	my $ins = json_utf8->decode($lei_out);
	my $exp = { "maildir:$x" => [ map { basename($_) } @x ],
		"maildir:$y" => [ map { basename($_) } @y ] };
	is_deeply($ins->{'mail-sync'}, $exp, 'inspect as expected');
	lei_ok qw(add-watch), $x;
	my $dst = $x[0] . 'S';
	rename($x[0], $dst) or xbail "rename($x[0], $dst): $!";
	my $ys = "$y[0]S";
	for (0..50) {
		last if -f $ys;
		tick; # wait for inotify or kevent
	}
	my @y2 = glob("$y/*/*");
	is_deeply(\@y2, [ $ys ], "`seen' kw propagated to `y' dir");
	lei_ok qw(note-event done);
	lei_ok qw(inspect), "blob:$oid";
	$ins = json_utf8->decode($lei_out);
	$exp = { "maildir:$x" => [ map { basename($_) } glob("$x/*/*") ],
		"maildir:$y" => [ map { basename($_) } glob("$y/*/*") ] };
	is_deeply($ins->{'mail-sync'}, $exp, 'mail_sync matches FS') or
		diag explain($ins);
});

done_testing;
