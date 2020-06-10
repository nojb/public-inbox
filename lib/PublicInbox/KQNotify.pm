# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# implements the small subset of Linux::Inotify2 functionality we use
# using IO::KQueue on *BSD systems.
package PublicInbox::KQNotify;
use strict;
use IO::KQueue;
use PublicInbox::DSKQXS; # wraps IO::KQueue for fork-safe DESTROY

# only true as far as public-inbox is concerned with .lock files:
sub IN_CLOSE () { NOTE_WRITE }
#sub IN_CLOSE () { 0x200 } # NOTE_CLOSE_WRITE (FreeBSD 11+ only)

sub new {
	my ($class) = @_;
	bless { dskq => PublicInbox::DSKQXS->new, watch => {} }, $class;
}

sub watch {
	my ($self, $path, $mask, $cb) = @_;
	open(my $fh, '<', $path) or return;
	my $ident = fileno($fh);
	$self->{dskq}->{kq}->EV_SET($ident, # ident
		EVFILT_VNODE, # filter
		EV_ADD | EV_CLEAR, # flags
		$mask, # fflags
		0, 0); # data, udata
	if ($mask == IN_CLOSE) {
		$self->{watch}->{$ident} = [ $fh, $cb ];
	} else {
		die "TODO Not implemented: $mask";
	}
}

# emulate Linux::Inotify::fileno
sub fileno { ${$_[0]->{dskq}->{kq}} }

# noop for Linux::Inotify2 compatibility.  Unlike inotify,
# kqueue doesn't seem to overflow since it's limited by the number of
# open FDs the process has
sub on_overflow {}

# noop for Linux::Inotify2 compatibility, we use `0' timeout for ->kevent
sub blocking {}

# behave like Linux::Inotify2::poll
sub poll {
	my ($self) = @_;
	my @kevents = $self->{dskq}->{kq}->kevent(0);
	for my $kev (@kevents) {
		my $ident = $kev->[KQ_IDENT];
		my $mask = $kev->[KQ_FFLAGS];
		if (($mask & IN_CLOSE) == IN_CLOSE) {
			eval { $self->{watch}->{$ident}->[1]->() };
		}
	}
}

1;