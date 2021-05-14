# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# implements the small subset of Linux::Inotify2 functionality we use
# using IO::KQueue on *BSD systems.
package PublicInbox::KQNotify;
use strict;
use v5.10.1;
use IO::KQueue;
use PublicInbox::DSKQXS; # wraps IO::KQueue for fork-safe DESTROY
use PublicInbox::FakeInotify qw(fill_dirlist on_dir_change);
use Time::HiRes qw(stat);

# NOTE_EXTEND detects rename(2), NOTE_WRITE detects link(2)
sub MOVED_TO_OR_CREATE () { NOTE_EXTEND|NOTE_WRITE }

sub new {
	my ($class) = @_;
	bless { dskq => PublicInbox::DSKQXS->new, watch => {} }, $class;
}

sub watch {
	my ($self, $path, $mask) = @_;
	my ($fh, $watch);
	if (-d $path) {
		opendir($fh, $path) or return;
		my @st = stat($fh);
		$watch = bless [ $fh, $path, $st[10] ],
			'PublicInbox::KQNotify::Watchdir';
	} else {
		open($fh, '<', $path) or return;
		$watch = bless [ $fh, $path ],
			'PublicInbox::KQNotify::Watch';
	}
	my $ident = fileno($fh);
	$self->{dskq}->{kq}->EV_SET($ident, # ident (fd)
		EVFILT_VNODE, # filter
		EV_ADD | EV_CLEAR, # flags
		$mask, # fflags
		0, 0); # data, udata
	if ($mask & (MOVED_TO_OR_CREATE|NOTE_DELETE|NOTE_LINK|NOTE_REVOKE)) {
		$self->{watch}->{$ident} = $watch;
		if ($mask & (NOTE_DELETE|NOTE_LINK|NOTE_REVOKE)) {
			fill_dirlist($self, $path, $fh)
		}
	} else {
		die "TODO Not implemented: $mask";
	}
	$watch;
}

# emulate Linux::Inotify::fileno
sub fileno { ${$_[0]->{dskq}->{kq}} }

# noop for Linux::Inotify2 compatibility.  Unlike inotify,
# kqueue doesn't seem to overflow since it's limited by the number of
# open FDs the process has
sub on_overflow {}

# noop for Linux::Inotify2 compatibility, we use `0' timeout for ->kevent
sub blocking {}

# behave like Linux::Inotify2->read
sub read {
	my ($self) = @_;
	my @kevents = $self->{dskq}->{kq}->kevent(0);
	my $events = [];
	my @gone;
	my $watch = $self->{watch};
	for my $kev (@kevents) {
		my $ident = $kev->[KQ_IDENT];
		my $mask = $kev->[KQ_FFLAGS];
		my ($dh, $path, $old_ctime) = @{$watch->{$ident}};
		if (!defined($old_ctime)) {
			push @$events,
				bless(\$path, 'PublicInbox::FakeInotify::Event')
		} elsif ($mask & (MOVED_TO_OR_CREATE|NOTE_DELETE|NOTE_LINK|
				NOTE_REVOKE|NOTE_RENAME)) {
			my @new_st = stat($path);
			if (!@new_st && $!{ENOENT}) {
				push @$events, bless(\$path,
						'PublicInbox::FakeInotify::'.
						'SelfGoneEvent');
				push @gone, $ident;
				delete $self->{dirlist}->{$path};
				next;
			}
			if (!@new_st) {
				warn "unhandled stat($path) error: $!\n";
				next;
			}
			$watch->{$ident}->[3] = $new_st[10]; # ctime
			rewinddir($dh);
			on_dir_change($events, $dh, $path, $old_ctime,
					$self->{dirlist});
		}
	}
	delete @$watch{@gone};
	@$events;
}

package PublicInbox::KQNotify::Watch;
use strict;

sub name { $_[0]->[1] }

sub cancel { close $_[0]->[0] or die "close: $!" }

package PublicInbox::KQNotify::Watchdir;
use strict;

sub name { $_[0]->[1] }

sub cancel { closedir $_[0]->[0] or die "closedir: $!" }

1;
