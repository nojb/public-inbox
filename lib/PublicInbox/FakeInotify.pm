# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for systems lacking Linux::Inotify2 or IO::KQueue, just emulates
# enough of Linux::Inotify2
package PublicInbox::FakeInotify;
use strict;
use v5.10.1;
use parent qw(Exporter);
use Time::HiRes qw(stat);
use PublicInbox::DS qw(add_timer);
sub IN_MODIFY () { 0x02 } # match Linux inotify
# my $IN_MOVED_FROM	 0x00000040	/* File was moved from X.  */
# my $IN_MOVED_TO = 0x80;
# my $IN_CREATE = 0x100;
sub MOVED_TO_OR_CREATE () { 0x80 | 0x100 }
sub IN_DELETE () { 0x200 }
sub IN_DELETE_SELF () { 0x400 }
sub IN_MOVE_SELF () { 0x800 }

our @EXPORT_OK = qw(fill_dirlist on_dir_change);

my $poll_intvl = 2; # same as Filesys::Notify::Simple

sub new { bless { watch => {}, dirlist => {} }, __PACKAGE__ }

sub fill_dirlist ($$$) {
	my ($self, $path, $dh) = @_;
	my $dirlist = $self->{dirlist}->{$path} = {};
	while (defined(my $n = readdir($dh))) {
		$dirlist->{$n} = undef if $n !~ /\A\.\.?\z/;
	}
}

# behaves like Linux::Inotify2->watch
sub watch {
	my ($self, $path, $mask) = @_;
	my @st = stat($path) or return;
	my $k = "$path\0$mask";
	$self->{watch}->{$k} = $st[10]; # 10 - ctime
	if ($mask & IN_DELETE) {
		opendir(my $dh, $path) or return;
		fill_dirlist($self, $path, $dh);
	}
	bless [ $self->{watch}, $k ], 'PublicInbox::FakeInotify::Watch';
}

# also used by KQNotify since it kevent requires readdir on st_nlink
# count changes.
sub on_dir_change ($$$$$) {
	my ($events, $dh, $path, $old_ctime, $dirlist) = @_;
	my $oldlist = $dirlist->{$path};
	my $newlist = $oldlist ? {} : undef;
	while (defined(my $base = readdir($dh))) {
		next if $base =~ /\A\.\.?\z/;
		my $full = "$path/$base";
		my @st = stat($full);
		if (@st && $st[10] > $old_ctime) {
			push @$events,
				bless(\$full, 'PublicInbox::FakeInotify::Event')
		}
		if (!@st) {
			# ignore ENOENT due to race
			warn "unhandled stat($full) error: $!\n" if !$!{ENOENT};
		} elsif ($newlist) {
			$newlist->{$base} = undef;
		}
	}
	return if !$newlist;
	delete @$oldlist{keys %$newlist};
	$dirlist->{$path} = $newlist;
	push(@$events, map {
		bless \"$path/$_", 'PublicInbox::FakeInotify::GoneEvent'
	} keys %$oldlist);
}

# behaves like non-blocking Linux::Inotify2->read
sub read {
	my ($self) = @_;
	my $watch = $self->{watch} or return ();
	my $events = [];
	my @watch_gone;
	for my $x (keys %$watch) {
		my ($path, $mask) = split(/\0/, $x, 2);
		my @now = stat($path);
		if (!@now && $!{ENOENT} && ($mask & IN_DELETE_SELF)) {
			push @$events, bless(\$path,
				'PublicInbox::FakeInotify::SelfGoneEvent');
			push @watch_gone, $x;
			delete $self->{dirlist}->{$path};
		}
		next if !@now;
		my $old_ctime = $watch->{$x};
		$watch->{$x} = $now[10];
		next if $old_ctime == $now[10];
		if ($mask & IN_MODIFY) {
			push @$events,
				bless(\$path, 'PublicInbox::FakeInotify::Event')
		} elsif ($mask & (MOVED_TO_OR_CREATE | IN_DELETE)) {
			if (opendir(my $dh, $path)) {
				on_dir_change($events, $dh, $path, $old_ctime,
						$self->{dirlist});
			} elsif ($!{ENOENT}) {
				push @watch_gone, $x;
				delete $self->{dirlist}->{$path};
			} else {
				warn "W: opendir $path: $!\n";
			}
		}
	}
	delete @$watch{@watch_gone};
	@$events;
}

sub poll_once {
	my ($obj) = @_;
	$obj->event_step; # PublicInbox::InboxIdle::event_step
	add_timer($poll_intvl, \&poll_once, $obj);
}

package PublicInbox::FakeInotify::Watch;
use strict;

sub cancel {
	my ($self) = @_;
	delete $self->[0]->{$self->[1]};
}

sub name {
	my ($self) = @_;
	(split(/\0/, $self->[1], 2))[0];
}

package PublicInbox::FakeInotify::Event;
use strict;

sub fullname { ${$_[0]} }

sub IN_DELETE { 0 }
sub IN_MOVED_FROM { 0 }
sub IN_DELETE_SELF { 0 }

package PublicInbox::FakeInotify::GoneEvent;
use strict;
our @ISA = qw(PublicInbox::FakeInotify::Event);

sub IN_DELETE { 1 }
sub IN_MOVED_FROM { 0 }

package PublicInbox::FakeInotify::SelfGoneEvent;
use strict;
our @ISA = qw(PublicInbox::FakeInotify::GoneEvent);

sub IN_DELETE_SELF { 1 }

1;
