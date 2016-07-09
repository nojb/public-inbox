# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# event cleanups (currently for Danga::Socket)
package PublicInbox::EvCleanup;
use strict;
use warnings;
use base qw(Danga::Socket);
use fields qw(rd);
my $singleton;
my $asapq = [ [], undef ];
my $nextq = [ [], undef ];
my $laterq = [ [], undef ];

sub once_init () {
	my $self = fields::new('PublicInbox::EvCleanup');
	my ($r, $w);
	pipe($r, $w) or die "pipe: $!";
	$self->SUPER::new($w);
	$self->{rd} = $r; # never read, since we never write..
	$self;
}

sub _run_all ($) {
	my ($q) = @_;

	my $run = $q->[0];
	$q->[0] = [];
	$q->[1] = undef;
	$_->() foreach @$run;
}

sub _run_asap () { _run_all($asapq) }
sub _run_next () { _run_all($nextq) }
sub _run_later () { _run_all($laterq) }

# Called by Danga::Socket
sub event_write {
	my ($self) = @_;
	$self->watch_write(0);
	_run_asap();
}

sub _asap_timer () {
	$singleton ||= once_init();
	$singleton->watch_write(1);
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
	$nextq->[1] ||= Danga::Socket->AddTimer(0, *_run_next);
}

sub later ($) {
	my ($cb) = @_;
	push @{$laterq->[0]}, $cb;
	$laterq->[1] ||= Danga::Socket->AddTimer(60, *_run_later);
}

END {
	_run_asap();
	_run_next();
	_run_later();
}

1;
