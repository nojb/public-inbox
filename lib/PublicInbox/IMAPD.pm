# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD (currently a singleton),
# see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use PublicInbox::Config;
use PublicInbox::InboxIdle;
use PublicInbox::IMAP;
use PublicInbox::DummyInbox;
my $dummy = bless { uidvalidity => 0 }, 'PublicInbox::DummyInbox';

sub new {
	my ($class) = @_;
	bless {
		mailboxes => {},
		err => \*STDERR,
		out => \*STDOUT,
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
		# pi_config => PublicInbox::Config
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub imapd_refresh_ibx { # pi_config->each_inbox cb
	my ($ibx, $imapd) = @_;
	my $ngname = $ibx->{newsgroup} or return;
	if (ref $ngname) {
		warn 'multiple newsgroups not supported: '.
			join(', ', @$ngname). "\n";
		return;
	} elsif ($ngname =~ m![^a-z0-9/_\.\-\~\@\+\=:]! ||
		 $ngname =~ /\.[0-9]+-[0-9]+\z/) {
		warn "mailbox name invalid: newsgroup=`$ngname'\n";
		return;
	}
	$ibx->over or return;
	$ibx->{over} = undef;
	my $mm = $ibx->mm or return;
	$ibx->{mm} = undef;

	# RFC 3501 2.3.1.1 -  "A good UIDVALIDITY value to use in
	# this case is a 32-bit representation of the creation
	# date/time of the mailbox"
	defined($ibx->{uidvalidity} = $mm->created_at) or return;
	PublicInbox::IMAP::ensure_ranges_exist($imapd, $ibx, $mm->max // 1);

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
	my ($imapd, $pi_config) = @_;
	my $mailboxes;
	if (my $next = delete $imapd->{imapd_next}) {
		$imapd->{mailboxes} = delete $next->{mailboxes};
		$mailboxes = delete $next->{dummies};
	} else {
		$mailboxes = delete $imapd->{dummies};
	}
	%$mailboxes = (%$mailboxes, %{$imapd->{mailboxes}});
	$imapd->{mailboxes} = $mailboxes;
	$imapd->{inboxlist} = [
		map {
			my $no = $mailboxes->{$_} == $dummy ? '' : 'No';
			qq[* LIST (\\Has${no}Children) "." $_\r\n]
		} sort {
			# shortest names first, alphabetically if lengths match
			length($a) == length($b) ?
				($a cmp $b) :
				(length($a) <=> length($b))
		} keys %$mailboxes
	];
	$imapd->{pi_config} = $pi_config;
	if (my $idler = $imapd->{idler}) {
		$idler->refresh($pi_config);
	}
}

sub imapd_refresh_step { # pi_config->iterate_start cb
	my ($pi_config, $section, $imapd) = @_;
	if (defined($section)) {
		return if $section !~ m!\Apublicinbox\.([^/]+)\z!;
		my $ibx = $pi_config->lookup_name($1) or return;
		imapd_refresh_ibx($ibx, $imapd->{imapd_next});
	} else { # undef == "EOF"
		imapd_refresh_finalize($imapd, $pi_config);
	}
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_config = PublicInbox::Config->new;
	if ($sig) { # SIGHUP is handled through the event loop
		$self->{imapd_next} = { dummies => {}, mailboxes => {} };
		$pi_config->iterate_start(\&imapd_refresh_step, $self);
		PublicInbox::DS::requeue($pi_config); # call event_step
	} else { # initial start is synchronous
		$self->{dummies} = {};
		$pi_config->each_inbox(\&imapd_refresh_ibx, $self);
		imapd_refresh_finalize($self, $pi_config);
	}
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_config});
}

1;
