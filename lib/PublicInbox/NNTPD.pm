# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an NNTPD (currently a singleton),
# see script/public-inbox-nntpd for how it is used
package PublicInbox::NNTPD;
use strict;
use v5.10.1;
use Sys::Hostname;
use PublicInbox::Config;
use PublicInbox::InboxIdle;
use PublicInbox::NNTP;

sub new {
	my ($class) = @_;
	bless {
		err => \*STDERR,
		out => \*STDOUT,
		# pi_cfg => $pi_cfg,
		# ssl_ctx_opt => { SSL_cert_file => ..., SSL_key_file => ... }
		# idler => PublicInbox::InboxIdle
	}, $class;
}

sub refresh_groups {
	my ($self, $sig) = @_;
	my $pi_cfg = PublicInbox::Config->new;
	my $name = $pi_cfg->{'publicinbox.nntpserver'};
	if (!defined($name) or $name eq '') {
		$name = hostname;
	} elsif (ref($name) eq 'ARRAY') {
		$name = $name->[0];
	}
	if ($name ne ($self->{servername} // '')) {
		$self->{servername} = $name;
		$self->{greet} = \"201 $name ready - post via email\r\n";
	}
	my $groups = $pi_cfg->{-by_newsgroup}; # filled during each_inbox
	my $cache = eval { $pi_cfg->ALL->misc->nntpd_cache_load } // {};
	$pi_cfg->each_inbox(sub {
		my ($ibx) = @_;
		my $ngname = $ibx->{newsgroup} // return;
		my $ce = $cache->{$ngname};
		if (($ce and (%$ibx = (%$ibx, %$ce))) || $ibx->nntp_usable) {
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
	@{$self->{groupnames}} = sort(keys %$groups);
	# this will destroy old groups that got deleted
	$self->{pi_cfg} = $pi_cfg;
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_cfg});
}

1;
