# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# event cleanups (currently for PublicInbox::DS)
package PublicInbox::EvCleanup;
use strict;
use warnings;
use base qw(PublicInbox::DS);
use PublicInbox::Syscall qw(EPOLLOUT EPOLLONESHOT);

my $ENABLED;
sub enabled { $ENABLED }
sub enable { $ENABLED = 1 }
my $singleton;
my $asapq = [ [], undef ];
my $nextq = [ [], undef ];
my $laterq = [ [], undef ];

sub once_init () {
	my $self = fields::new('PublicInbox::EvCleanup');
	my ($r, $w);

	# This is a dummy pipe which is always writable so it can always
	# fires in the next event loop iteration.
	pipe($r, $w) or die "pipe: $!";
	fcntl($w, 1031, 4096) if $^O eq 'linux'; # 1031: F_SETPIPE_SZ
	$self->SUPER::new($w, 0);

	# always writable, since PublicInbox::EvCleanup::event_step
	# never drains wbuf.  We can avoid wasting a hash slot by
	# stuffing the read-end of the pipe into the never-to-be-touched
	# wbuf
	$self->{wbuf} = $r;
	$self;
}

sub _run_all ($) {
	my ($q) = @_;

	my $run = $q->[0];
	$q->[0] = [];
	$q->[1] = undef;
	$_->() foreach @$run;
}

# ensure PublicInbox::DS::ToClose processing after timers fire
sub _asap_close () { $asapq->[1] ||= _asap_timer() }

# Called by PublicInbox::DS
sub event_step { _run_all($asapq) }

sub _run_next () {
	_run_all($nextq);
	_asap_close();
}

sub _run_later () {
	_run_all($laterq);
	_asap_close();
}

sub _asap_timer () {
	$singleton ||= once_init();
	$singleton->watch(EPOLLOUT|EPOLLONESHOT);
	1;
}

sub asap ($) {
	my ($cb) = @_;
	push @{$asapq->[0]}, $cb;
	$asapq->[1] ||= _asap_timer();
}

sub next_tick ($) {
	my ($cb) = @_;
	push @{$nextq->[0]}, $cb;
	$nextq->[1] ||= PublicInbox::DS->AddTimer(0, *_run_next);
}

sub later ($) {
	my ($cb) = @_;
	push @{$laterq->[0]}, $cb;
	$laterq->[1] ||= PublicInbox::DS->AddTimer(60, *_run_later);
}

END {
	event_step();
	_run_all($nextq);
	_run_all($laterq);
}

1;
