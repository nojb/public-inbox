# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD (currently a singleton),
# see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use v5.10.1;
use PublicInbox::Config;
use PublicInbox::ConfigIter;
use PublicInbox::InboxIdle;
use PublicInbox::IMAPdeflate; # loads PublicInbox::IMAP
use PublicInbox::DummyInbox;
my $dummy = bless { uidvalidity => 0 }, 'PublicInbox::DummyInbox';

sub new {
	my ($class) = @_;
	bless {
		mailboxes => {},
		err => \*STDERR,
		out => \*STDOUT,
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
		# pi_cfg => PublicInbox::Config
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub imapd_refresh_ibx { # pi_cfg->each_inbox cb
	my ($ibx, $imapd) = @_;
	my $ngname = $ibx->{newsgroup} or return;

	# We require lower-case since IMAP mailbox names are
	# case-insensitive (but -nntpd matches INN in being
	# case-sensitive
	if ($ngname =~ m![^a-z0-9/_\.\-\~\@\+\=:]! ||
			# don't confuse with 50K slices
			$ngname =~ /\.[0-9]+\z/) {
		warn "mailbox name invalid: newsgroup=`$ngname'\n";
		return;
	}
	$ibx->over or return;
	$ibx->{over} = undef;

	# RFC 3501 2.3.1.1 -  "A good UIDVALIDITY value to use in
	# this case is a 32-bit representation of the creation
	# date/time of the mailbox"
	eval { $ibx->uidvalidity };
	my $mm = delete($ibx->{mm}) or return;
	defined($ibx->{uidvalidity}) or return;
	PublicInbox::IMAP::ensure_slices_exist($imapd, $ibx, $mm->max);

	# preload to avoid fragmentation:
	$ibx->description;
	$ibx->base_url;

	# ensure dummies are selectable
	my $dummies = $imapd->{dummies};
	do {
		$dummies->{$ngname} = $dummy;
	} while ($ngname =~ s/\.[^\.]+\z//);
}

sub imapd_refresh_finalize {
	my ($imapd, $pi_cfg) = @_;
	my $mailboxes;
	if (my $next = delete $imapd->{imapd_next}) {
		$imapd->{mailboxes} = delete $next->{mailboxes};
		$mailboxes = delete $next->{dummies};
	} else {
		$mailboxes = delete $imapd->{dummies};
	}
	%$mailboxes = (%$mailboxes, %{$imapd->{mailboxes}});
	$imapd->{mailboxes} = $mailboxes;
	$imapd->{mailboxlist} = [
		map { $_->[2] }
		sort { $a->[0] cmp $b->[0] || $a->[1] <=> $b->[1] }
		map {
			my $u = $_; # capitalize "INBOX" for user-familiarity
			$u =~ s/\Ainbox(\.|\z)/INBOX$1/i;
			if ($mailboxes->{$_} == $dummy) {
				[ $u, -1,
				  qq[* LIST (\\HasChildren) "." $u\r\n]]
			} else {
				$u =~ /\A(.+)\.([0-9]+)\z/ or
					die "BUG: `$u' has no slice digit(s)";
				[ $1, $2 + 0,
				  qq[* LIST (\\HasNoChildren) "." $u\r\n] ]
			}
		} keys %$mailboxes
	];
	$imapd->{pi_cfg} = $pi_cfg;
	if (my $idler = $imapd->{idler}) {
		$idler->refresh($pi_cfg);
	}
}

sub imapd_refresh_step { # pi_cfg->iterate_start cb
	my ($pi_cfg, $section, $imapd) = @_;
	if (defined($section)) {
		return if $section !~ m!\Apublicinbox\.([^/]+)\z!;
		my $ibx = $pi_cfg->lookup_name($1) or return;
		imapd_refresh_ibx($ibx, $imapd->{imapd_next});
	} else { # undef == "EOF"
		imapd_refresh_finalize($imapd, $pi_cfg);
	}
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_cfg = PublicInbox::Config->new;
	if ($sig) { # SIGHUP is handled through the event loop
		$self->{imapd_next} = { dummies => {}, mailboxes => {} };
		my $iter = PublicInbox::ConfigIter->new($pi_cfg,
						\&imapd_refresh_step, $self);
		$iter->event_step;
	} else { # initial start is synchronous
		$self->{dummies} = {};
		$pi_cfg->each_inbox(\&imapd_refresh_ibx, $self);
		imapd_refresh_finalize($self, $pi_cfg);
	}
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_cfg});
}

1;
