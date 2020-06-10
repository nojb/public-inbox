# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for systems lacking Linux::Inotify2 or IO::KQueue, just emulates
# enough of Linux::Inotify2
package PublicInbox::FakeInotify;
use strict;
use Time::HiRes qw(stat);
my $IN_CLOSE = 0x08 | 0x10; # match Linux inotify

my $poll_intvl = 2; # same as Filesys::Notify::Simple
my $for_cancel = bless \(my $x), 'PublicInbox::FakeInotify::Watch';

sub poll_once {
	my ($self) = @_;
	sub {
		eval { $self->poll };
		warn "E: FakeInotify->poll: $@\n" if $@;
		PublicInbox::DS::add_timer($poll_intvl, poll_once($self));
	};
}

sub new {
	my $self = bless { watch => {} }, __PACKAGE__;
	PublicInbox::DS::add_timer($poll_intvl, poll_once($self));
	$self;
}

# behaves like Linux::Inotify2->watch
sub watch {
	my ($self, $path, $mask, $cb) = @_;
	my @st = stat($path) or return;
	$self->{watch}->{"$path\0$mask"} = [ @st, $cb ];
	$for_cancel;
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

package PublicInbox::FakeInotify::Watch;
sub cancel {} # noop

1;
