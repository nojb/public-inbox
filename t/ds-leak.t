# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict; use v5.10.1; use PublicInbox::TestCommon;
use_ok 'PublicInbox::DS';

if ('close-on-exec for epoll and kqueue') {
	use PublicInbox::Spawn qw(spawn);
	my $pid;
	my $evfd_re = qr/(?:kqueue|eventpoll)/i;

	PublicInbox::DS->SetLoopTimeout(0);
	PublicInbox::DS->SetPostLoopCallback(sub { 0 });

	# make sure execve closes if we're using fork()
	my ($r, $w);
	pipe($r, $w) or die "pipe: $!";

	PublicInbox::DS::add_timer(0, sub { $pid = spawn([qw(sleep 10)]) });
	PublicInbox::DS::event_loop();
	ok($pid, 'subprocess spawned');

	# wait for execve, we need to ensure lsof sees sleep(1)
	# and not the fork of this process:
	close $w or die "close: $!";
	my $l = <$r>;
	is($l, undef, 'cloexec works and sleep(1) is running');

	SKIP: {
		my $lsof = require_cmd('lsof', 1) or skip 'lsof missing', 1;
		my $rdr = { 2 => \(my $null) };
		my @of = grep(/$evfd_re/, xqx([$lsof, '-p', $pid], {}, $rdr));
		my $err = $?;
		skip "lsof broken ? (\$?=$err)", 1 if $err;
		is_deeply(\@of, [], 'no FDs leaked to subprocess');
	};
	if (defined $pid) {
		kill(9, $pid);
		waitpid($pid, 0);
	}
	PublicInbox::DS->Reset;
}

SKIP: {
	require_mods('BSD::Resource', 1);
	my $rlim = BSD::Resource::RLIMIT_NOFILE();
	my ($n,undef) = BSD::Resource::getrlimit($rlim);

	# FreeBSD 11.2 with 2GB RAM gives RLIMIT_NOFILE=57987!
	if ($n > 1024 && !$ENV{TEST_EXPENSIVE}) {
		skip "RLIMIT_NOFILE=$n too big w/o TEST_EXPENSIVE for $0", 1;
	}
	my $cb = sub {};
	for my $i (0..$n) {
		PublicInbox::DS->SetLoopTimeout(0);
		PublicInbox::DS->SetPostLoopCallback($cb);
		PublicInbox::DS::event_loop();
		PublicInbox::DS->Reset;
	}
	ok(1, "Reset works and doesn't hit RLIMIT_NOFILE ($n)");
};

done_testing;
