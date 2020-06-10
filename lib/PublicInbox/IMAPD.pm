# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD (currently a singleton),
# see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use parent qw(PublicInbox::NNTPD);
use PublicInbox::InboxIdle;
use PublicInbox::IMAP;
# *UID_BLOCK = \&PublicInbox::IMAP::UID_BLOCK;

sub new {
	my ($class) = @_;
	bless {
		groups => {},
		err => \*STDERR,
		out => \*STDOUT,
		grouplist => [],
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
		# pi_config => PublicInbox::Config
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub refresh_inboxlist ($) {
	my ($self) = @_;
	my @names = map { $_->{newsgroup} } @{delete $self->{grouplist}};
	my %ns; # "\Noselect \HasChildren"

	if (my @uc = grep(/[A-Z]/, @names)) {
		warn "Uppercase not allowed for IMAP newsgroup(s):\n",
			map { "\t$_\n" } @uc;
		my %uc = map { $_ => 1 } @uc;
		@names = grep { !$uc{$_} } @names;
	}
	for (@names) {
		my $up = $_;
		while ($up =~ s/\.[^\.]+\z//) {
			$ns{$up} = '\\Noselect \\HasChildren';
		}
	}
	@names = map {;
		my $at = delete($ns{$_}) ? '\\HasChildren' : '\\HasNoChildren';
		qq[* LIST ($at) "." $_\r\n]
	} @names;
	push(@names, map { qq[* LIST ($ns{$_}) "." $_\r\n] } keys %ns);
	@names = sort {
		my ($xa) = ($a =~ / (\S+)\r\n/g);
		my ($xb) = ($b =~ / (\S+)\r\n/g);
		length($xa) <=> length($xb);
	} @names;
	$self->{inboxlist} = \@names;
}

sub imapd_refresh_ibx { # pi_config->each_inbox cb
	my ($ibx, $imapd) = @_;
	my $ngname = $ibx->{newsgroup} or return;
	if (ref $ngname) {
		warn 'multiple newsgroups not supported: '.
			join(', ', @$ngname). "\n";
	} elsif ($ngname =~ m![^a-z0-9/_\.\-\~\@\+\=:]! ||
		 $ngname =~ /\.[0-9]+-[0-9]+\z/) {
		warn "mailbox name invalid: `$ngname'\n";
	}

	my $mm = $ibx->mm or return;
	$ibx->{mm} = undef;
	defined($ibx->{uidvalidity} = $mm->created_at) or return;
	$imapd->{tmp_groups}->{$ngname} = $ibx;

	# preload to avoid fragmentation:
	$ibx->description;
	$ibx->base_url;
	# my $max = $mm->max // 0;
	# my $uid_min = UID_BLOCK * int($max/UID_BLOCK) + 1;
}

sub imapd_refresh_finalize {
	my ($imapd, $pi_config) = @_;
	$imapd->{groups} = delete $imapd->{tmp_groups};
	$imapd->{grouplist} = [ values %{$imapd->{groups}} ];
	refresh_inboxlist($imapd);
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
		imapd_refresh_ibx($ibx, $imapd);
	} else { # "EOF"
		imapd_refresh_finalize($imapd, $pi_config);
	}
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_config = PublicInbox::Config->new;
	$self->{tmp_groups} = {};
	if (0 && $sig) { # SIGHUP
		$pi_config->iterate_start(\&imapd_refresh_step, $self);
		PublicInbox::DS::requeue($pi_config); # call event_step
	} else { # initial start
		$pi_config->each_inbox(\&imapd_refresh_ibx, $self);
		imapd_refresh_finalize($self, $pi_config);
	}
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_config});
}

1;
