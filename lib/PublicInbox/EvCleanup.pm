# Copyright (C) 2016-2019 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# event cleanups (for PublicInbox::DS)
package PublicInbox::EvCleanup;
use strict;
use warnings;
require PublicInbox::DS;

# this only runs under public-inbox-{httpd/nntpd}, not generic PSGI servers
my $ENABLED;
sub enabled { $ENABLED }
sub enable { $ENABLED = 1 }
my $laterq = [ [], undef ];

sub _run_later () {
	my $run = $laterq->[0];
	$laterq->[0] = [];
	$laterq->[1] = undef;
	$_->() foreach @$run;
}

sub later ($) {
	my ($cb) = @_;
	push @{$laterq->[0]}, $cb;
	$laterq->[1] ||= PublicInbox::DS->AddTimer(60, *_run_later);
}

END { _run_later() }
1;
