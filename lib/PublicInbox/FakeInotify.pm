# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for systems lacking Linux::Inotify2 or IO::KQueue, just emulates
# enough of Linux::Inotify2
package PublicInbox::FakeInotify;
use strict;
use Time::HiRes qw(stat);
my $IN_CLOSE = 0x08 | 0x10; # match Linux inotify

sub new { bless { watch => {} }, __PACKAGE__ }

# behaves like Linux::Inotify2->watch
sub watch {
	my ($self, $path, $mask, $cb) = @_;
	my @st = stat($path) or return;
	$self->{watch}->{"$path\0$mask"} = [ @st, $cb ];
}

# behaves like non-blocking Linux::Inotify2->poll
sub poll {
	my ($self) = @_;
	my $watch = $self->{watch} or return;
	for my $x (keys %$watch) {
		my ($path, $mask) = split(/\0/, $x, 2);
		my @now = stat($path) or next;
		my $prv = $watch->{$x};
		my $cb = $prv->[-1];
		# 10: ctime, 7: size
		if ($prv->[10] != $now[10]) {
			if (($mask & $IN_CLOSE) == $IN_CLOSE) {
				eval { $cb->() };
			}
		}
		@$prv = (@now, $cb);
	}
}

1;
