# Copyright (C) 2019 all contributors <meta@public-inbox.org>
# Licensed the same as Danga::Socket (and Perl5)
# License: GPL-1.0+ or Artistic-1.0-Perl
#  <https://www.gnu.org/licenses/gpl-1.0.txt>
#  <https://dev.perl.org/licenses/artistic.html>
use strict;
use warnings;
use Test::More;
use_ok 'PublicInbox::DS';

if ('close-on-exec for epoll and kqueue') {
	use PublicInbox::Spawn qw(spawn);
	my $pid;
	my $evfd_re = qr/(?:kqueue|eventpoll)/i;

	PublicInbox::DS->SetLoopTimeout(0);
	PublicInbox::DS->SetPostLoopCallback(sub { 0 });
	PublicInbox::DS->AddTimer(0, sub { $pid = spawn([qw(sleep 10)]) });
	PublicInbox::DS->EventLoop;
	ok($pid, 'subprocess spawned');
	my @of = grep(/$evfd_re/, `lsof -p $pid 2>/dev/null`);
	my $err = $?;
	SKIP: {
		skip "lsof missing? (\$?=$err)", 1 if $err;
		is_deeply(\@of, [], 'no FDs leaked to subprocess');
	};
	if (defined $pid) {
		kill(9, $pid);
		waitpid($pid, 0);
	}
	PublicInbox::DS->Reset;
}

SKIP: {
	# not bothering with BSD::Resource
	chomp(my $n = `/bin/sh -c 'ulimit -n'`);

	# FreeBSD 11.2 with 2GB RAM gives RLIMIT_NOFILE=57987!
	if ($n > 1024 && !$ENV{TEST_EXPENSIVE}) {
		skip "RLIMIT_NOFILE=$n too big w/o TEST_EXPENSIVE for $0", 1;
	}
	my $cb = sub {};
	for my $i (0..$n) {
		PublicInbox::DS->SetLoopTimeout(0);
		PublicInbox::DS->SetPostLoopCallback($cb);
		PublicInbox::DS->EventLoop;
		PublicInbox::DS->Reset;
	}
	ok(1, "Reset works and doesn't hit RLIMIT_NOFILE ($n)");
};

done_testing;
