# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# Used by public-inbox-watch for Maildir (and possibly MH in the future)
package PublicInbox::DirIdle;
use strict;
use parent 'PublicInbox::DS';
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
use PublicInbox::In2Tie;

my ($MAIL_IN, $MAIL_GONE, $ino_cls);
if ($^O eq 'linux' && eval { require Linux::Inotify2; 1 }) {
	$MAIL_IN = Linux::Inotify2::IN_MOVED_TO() |
		Linux::Inotify2::IN_CREATE();
	$MAIL_GONE = Linux::Inotify2::IN_DELETE();
	$ino_cls = 'Linux::Inotify2';
# Perl 5.22+ is needed for fileno(DIRHANDLE) support:
} elsif ($^V ge v5.22 && eval { require PublicInbox::KQNotify }) {
	$MAIL_IN = PublicInbox::KQNotify::MOVED_TO_OR_CREATE();
	$MAIL_GONE = PublicInbox::KQNotify::NOTE_DELETE();
	$ino_cls = 'PublicInbox::KQNotify';
} else {
	require PublicInbox::FakeInotify;
	$MAIL_IN = PublicInbox::FakeInotify::MOVED_TO_OR_CREATE();
	$MAIL_GONE = PublicInbox::FakeInotify::IN_DELETE();
}

sub new {
	my ($class, $dirs, $cb, $gone) = @_;
	my $self = bless { cb => $cb }, $class;
	my $inot;
	if ($ino_cls) {
		$inot = $ino_cls->new or die "E: $ino_cls->new: $!";
		my $io = PublicInbox::In2Tie::io($inot);
		$self->SUPER::new($io, EPOLLIN | EPOLLET);
	} else {
		require PublicInbox::FakeInotify;
		$inot = PublicInbox::FakeInotify->new; # starts timer
	}

	# Linux::Inotify2->watch or similar
	my $fl = $MAIL_IN;
	$fl |= $MAIL_GONE if $gone;
	$inot->watch($_, $fl) for @$dirs;
	$self->{inot} = $inot;
	PublicInbox::FakeInotify::poll_once($self) if !$ino_cls;
	$self;
}

sub event_step {
	my ($self) = @_;
	my $cb = $self->{cb};
	local $PublicInbox::DS::in_loop = 0; # waitpid() synchronously
	eval {
		my @events = $self->{inot}->read; # Linux::Inotify2->read
		$cb->($_) for @events;
	};
	warn "$self->{inot}->read err: $@\n" if $@;
}

1;
