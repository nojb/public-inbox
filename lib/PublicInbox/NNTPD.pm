# Copyright (C) 2016-2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an NNTPD (currently a singleton),
# see script/public-inbox-nntpd for how it is used
package PublicInbox::NNTPD;
use strict;
use warnings;
use Sys::Hostname;
use PublicInbox::Config;
use PublicInbox::InboxIdle;

sub new {
	my ($class) = @_;
	my $pi_config = PublicInbox::Config->new;
	my $name = $pi_config->{'publicinbox.nntpserver'};
	if (!defined($name) or $name eq '') {
		$name = hostname;
	} elsif (ref($name) eq 'ARRAY') {
		$name = $name->[0];
	}

	bless {
		groups => {},
		err => \*STDERR,
		out => \*STDOUT,
		pi_config => $pi_config,
		servername => $name,
		greet => \"201 $name ready - post via email\r\n",
		# accept_tls => { SSL_server => 1, ..., SSL_reuse_ctx => ... }
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_config = $sig ? PublicInbox::Config->new : $self->{pi_config};
	my $groups = $pi_config->{-by_newsgroup}; # filled during each_inbox
	$pi_config->each_inbox(sub {
		my ($ibx) = @_;
		my $ngname = $ibx->{newsgroup};
		if (defined($ngname) && $ibx->nntp_usable) {
			# only valid if msgmap and over works
			# preload to avoid fragmentation:
			$ibx->description;
			$ibx->base_url;
		} else {
			delete $groups->{$ngname};
			delete $ibx->{newsgroup};
			# Note: don't be tempted to delete more for memory
			# savings just yet: NNTP, IMAP, and WWW may all
			# run in the same process someday.
		}
	});
	$self->{groupnames} = [ sort(keys %$groups) ];
	# this will destroy old groups that got deleted
	$self->{pi_config} = $pi_config;
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_config});
}

1;
