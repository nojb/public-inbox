# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# fields:
# inot: Linux::Inotify2-like object
# pathmap => { inboxdir => [ ibx, watch1, watch2, watch3... ] } mapping
package PublicInbox::InboxIdle;
use strict;
use parent qw(PublicInbox::DS);
use Cwd qw(abs_path);
use PublicInbox::Syscall qw(EPOLLIN EPOLLET);
my $IN_MODIFY = 0x02; # match Linux inotify
my $ino_cls;
if ($^O eq 'linux' && eval { require Linux::Inotify2; 1 }) {
	$IN_MODIFY = Linux::Inotify2::IN_MODIFY();
	$ino_cls = 'Linux::Inotify2';
} elsif (eval { require PublicInbox::KQNotify }) {
	$IN_MODIFY = PublicInbox::KQNotify::NOTE_WRITE();
	$ino_cls = 'PublicInbox::KQNotify';
}
require PublicInbox::In2Tie if $ino_cls;

sub in2_arm ($$) { # PublicInbox::Config::each_inbox callback
	my ($ibx, $self) = @_;
	my $dir = abs_path($ibx->{inboxdir});
	if (!defined($dir)) {
		warn "W: $ibx->{inboxdir} not watched: $!\n";
		return;
	}
	my $inot = $self->{inot};
	my $cur = $self->{pathmap}->{$dir} //= [];

	# transfer old subscriptions to the current inbox, cancel the old watch
	if (my $old_ibx = $cur->[0]) {
		$ibx->{unlock_subs} and
			die "BUG: $dir->{unlock_subs} should not exist";
		$ibx->{unlock_subs} = $old_ibx->{unlock_subs};
		$cur->[1]->cancel; # Linux::Inotify2::Watch::cancel
	}
	$cur->[0] = $ibx;

	my $lock = "$dir/".($ibx->version >= 2 ? 'inbox.lock' : 'ssoma.lock');
	if (my $w = $cur->[1] = $inot->watch($lock, $IN_MODIFY)) {
		$self->{on_unlock}->{$w->name} = $ibx;
	} else {
		warn "E: ".ref($inot)."->watch($lock, IN_MODIFY) failed: $!\n";
	}

	# TODO: detect deleted packs (and possibly other files)
}

sub refresh {
	my ($self, $pi_cfg) = @_;
	$pi_cfg->each_inbox(\&in2_arm, $self);
}

sub new {
	my ($class, $pi_cfg) = @_;
	my $self = bless {}, $class;
	my $inot;
	if ($ino_cls) {
		$inot = $ino_cls->new or die "E: $ino_cls->new: $!";
		my $io = PublicInbox::In2Tie::io($inot);
		$self->SUPER::new($io, EPOLLIN | EPOLLET);
	} else {
		require PublicInbox::FakeInotify;
		$inot = PublicInbox::FakeInotify->new;
	}
	$self->{inot} = $inot;
	$self->{pathmap} = {}; # inboxdir => [ ibx, watch1, watch2, watch3...]
	$self->{on_unlock} = {}; # lock path => ibx
	refresh($self, $pi_cfg);
	PublicInbox::FakeInotify::poll_once($self) if !$ino_cls;
	$self;
}

sub event_step {
	my ($self) = @_;
	eval {
		my @events = $self->{inot}->read; # Linux::Inotify2::read
		my $on_unlock = $self->{on_unlock};
		for my $ev (@events) {
			if (my $ibx = $on_unlock->{$ev->fullname}) {
				$ibx->on_unlock;
			}
		}
	};
	warn "{inot}->read err: $@\n" if $@;
}

# for graceful shutdown in PublicInbox::Daemon,
# just ensure the FD gets closed ASAP and subscribers
sub busy { 0 }

1;
