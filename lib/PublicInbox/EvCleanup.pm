# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# event cleanups (currently for Danga::Socket)
package PublicInbox::EvCleanup;
use strict;
use warnings;

my $asapq = { queue => [], timer => undef };
my $laterq = { queue => [], timer => undef };

sub _run_all ($) {
	my ($q) = @_;

	my $run = $q->{queue};
	$q->{queue} = [];
	$q->{timer} = undef;
	$_->() foreach @$run;
}

sub _run_asap () { _run_all($asapq) }
sub _run_later () { _run_all($laterq) }

sub asap ($) {
	my ($cb) = @_;
	push @{$asapq->{queue}}, $cb;
	$asapq->{timer} ||= Danga::Socket->AddTimer(0, *_run_asap);
}

sub later ($) {
	my ($cb) = @_;
	push @{$laterq->{queue}}, $cb;
	$laterq->{timer} ||= Danga::Socket->AddTimer(60, *_run_later);
}

END {
	_run_asap();
	_run_later();
}

1;
