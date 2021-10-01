# Copyright (C) 2019-2021 all contributors <meta@public-inbox.org>
use strict;
use Test::More;
use IO::Handle;
use POSIX qw(:signal_h);
use Errno qw(ENOSYS);
require_ok 'PublicInbox::Sigfd';
use PublicInbox::DS;

SKIP: {
	if ($^O ne 'linux' && !eval { require IO::KQueue }) {
		skip 'signalfd requires Linux or IO::KQueue to emulate', 10;
	}

	my $old = PublicInbox::DS::block_signals();
	my $hit = {};
	my $sig = {};
	local $SIG{HUP} = sub { $hit->{HUP}->{normal}++ };
	local $SIG{TERM} = sub { $hit->{TERM}->{normal}++ };
	local $SIG{INT} = sub { $hit->{INT}->{normal}++ };
	for my $s (qw(HUP TERM INT)) {
		$sig->{$s} = sub { $hit->{$s}->{sigfd}++ };
	}
	my $sigfd = PublicInbox::Sigfd->new($sig, 0);
	if ($sigfd) {
		ok($sigfd, 'Sigfd->new works');
		kill('HUP', $$) or die "kill $!";
		kill('INT', $$) or die "kill $!";
		my $fd = fileno($sigfd->{sock});
		ok($fd >= 0, 'fileno(Sigfd->{sock}) works');
		my $rvec = '';
		vec($rvec, $fd, 1) = 1;
		is(select($rvec, undef, undef, undef), 1, 'select() works');
		ok($sigfd->wait_once, 'wait_once reported success');
		for my $s (qw(HUP INT)) {
			is($hit->{$s}->{sigfd}, 1, "sigfd fired $s");
			is($hit->{$s}->{normal}, undef,
				'normal $SIG{$s} not fired');
		}
		$sigfd = undef;

		my $nbsig = PublicInbox::Sigfd->new($sig, 1);
		ok($nbsig, 'Sigfd->new SFD_NONBLOCK works');
		is($nbsig->wait_once, undef, 'nonblocking ->wait_once');
		ok($! == Errno::EAGAIN, 'got EAGAIN');
		kill('HUP', $$) or die "kill $!";
		PublicInbox::DS->SetPostLoopCallback(sub {}); # loop once
		PublicInbox::DS::event_loop();
		is($hit->{HUP}->{sigfd}, 2, 'HUP sigfd fired in event loop') or
			diag explain($hit); # sometimes fails on FreeBSD 11.x
		kill('TERM', $$) or die "kill $!";
		kill('HUP', $$) or die "kill $!";
		PublicInbox::DS::event_loop();
		PublicInbox::DS->Reset;
		is($hit->{TERM}->{sigfd}, 1, 'TERM sigfd fired in event loop');
		is($hit->{HUP}->{sigfd}, 3, 'HUP sigfd fired in event loop');
	} else {
		skip('signalfd disabled?', 10);
	}
	sigprocmask(SIG_SETMASK, $old) or die "sigprocmask $!";
}

done_testing;
