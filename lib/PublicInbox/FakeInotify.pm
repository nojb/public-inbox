# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# for systems lacking Linux::Inotify2 or IO::KQueue, just emulates
# enough of Linux::Inotify2
package PublicInbox::FakeInotify;
use strict;
use Time::HiRes qw(stat);
use PublicInbox::DS;
my $IN_CLOSE = 0x08 | 0x10; # match Linux inotify
# my $IN_MOVED_TO = 0x80;
# my $IN_CREATE = 0x100;
sub MOVED_TO_OR_CREATE () { 0x80 | 0x100 }

my $poll_intvl = 2; # same as Filesys::Notify::Simple

sub poll_once {
	my ($self) = @_;
	eval { $self->poll };
	warn "E: FakeInotify->poll: $@\n" if $@;
	PublicInbox::DS::add_timer($poll_intvl, \&poll_once, $self);
}

sub new {
	my $self = bless { watch => {} }, __PACKAGE__;
	PublicInbox::DS::add_timer($poll_intvl, \&poll_once, $self);
	$self;
}

# behaves like Linux::Inotify2->watch
sub watch {
	my ($self, $path, $mask, $cb) = @_;
	my @st = stat($path) or return;
	my $k = "$path\0$mask";
	$self->{watch}->{$k} = [ $st[10], $cb ]; # 10 - ctime
	bless [ $self->{watch}, $k ], 'PublicInbox::FakeInotify::Watch';
}

sub on_new_files ($$$$) {
	my ($dh, $cb, $path, $old_ctime) = @_;
	while (defined(my $base = readdir($dh))) {
		next if $base =~ /\A\.\.?\z/;
		my $full = "$path/$base";
		my @st = stat($full);
		if (@st && $st[10] > $old_ctime) {
			bless \$full, 'PublicInbox::FakeInotify::Event';
			eval { $cb->(\$full) };
		}
	}
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
		my $old_ctime = $prv->[0];
		if ($old_ctime != $now[10]) {
			if (($mask & $IN_CLOSE) == $IN_CLOSE) {
				eval { $cb->() };
			} elsif ($mask & MOVED_TO_OR_CREATE) {
				opendir(my $dh, $path) or do {
					warn "W: opendir $path: $!\n";
					next;
				};
				on_new_files($dh, $cb, $path, $old_ctime);
			}
		}
		@$prv = ($now[10], $cb);
	}
}

package PublicInbox::FakeInotify::Watch;
use strict;

sub cancel {
	my ($self) = @_;
	delete $self->[0]->{$self->[1]};
}

package PublicInbox::FakeInotify::Event;
use strict;

sub fullname { ${$_[0]} }
1;
