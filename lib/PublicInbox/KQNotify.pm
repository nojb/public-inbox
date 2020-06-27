# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# implements the small subset of Linux::Inotify2 functionality we use
# using IO::KQueue on *BSD systems.
package PublicInbox::KQNotify;
use strict;
use IO::KQueue;
use PublicInbox::DSKQXS; # wraps IO::KQueue for fork-safe DESTROY
use PublicInbox::FakeInotify;
use Time::HiRes qw(stat);

# NOTE_EXTEND detects rename(2), NOTE_WRITE detects link(2)
sub MOVED_TO_OR_CREATE () { NOTE_EXTEND|NOTE_WRITE }

sub new {
	my ($class) = @_;
	bless { dskq => PublicInbox::DSKQXS->new, watch => {} }, $class;
}

sub watch {
	my ($self, $path, $mask, $cb) = @_;
	my ($fh, $cls, @extra);
	if (-d $path) {
		opendir($fh, $path) or return;
		my @st = stat($fh);
		@extra = ($path, $st[10]); # 10: ctime
		$cls = 'PublicInbox::KQNotify::Watchdir';
	} else {
		open($fh, '<', $path) or return;
		$cls = 'PublicInbox::KQNotify::Watch';
	}
	my $ident = fileno($fh);
	$self->{dskq}->{kq}->EV_SET($ident, # ident
		EVFILT_VNODE, # filter
		EV_ADD | EV_CLEAR, # flags
		$mask, # fflags
		0, 0); # data, udata
	if ($mask == NOTE_WRITE || $mask == MOVED_TO_OR_CREATE) {
		$self->{watch}->{$ident} = [ $fh, $cb, @extra ];
	} else {
		die "TODO Not implemented: $mask";
	}
	bless \$fh, $cls;
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
		my ($dh, $cb, $path, $old_ctime) = @{$self->{watch}->{$ident}};
		if (!defined($path) && ($mask & NOTE_WRITE) == NOTE_WRITE) {
			eval { $cb->() };
		} elsif ($mask & MOVED_TO_OR_CREATE) {
			my @new_st = stat($path) or next;
			$self->{watch}->{$ident}->[3] = $new_st[10]; # ctime
			rewinddir($dh);
			PublicInbox::FakeInotify::on_new_files($dh, $cb,
							$path, $old_ctime);
		}
	}
}

package PublicInbox::KQNotify::Watch;
use strict;

sub cancel { close ${$_[0]} or die "close: $!" }

package PublicInbox::KQNotify::Watchdir;
use strict;

sub cancel { closedir ${$_[0]} or die "closedir: $!" }

1;
