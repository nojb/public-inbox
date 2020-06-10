# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# represents an IMAPD (currently a singleton),
# see script/public-inbox-imapd for how it is used
package PublicInbox::IMAPD;
use strict;
use parent qw(PublicInbox::NNTPD);
use PublicInbox::InboxIdle;

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

sub refresh_groups {
	my ($self) = @_;
	my $pi_config = $self->{pi_config} = PublicInbox::Config->new;
	$self->SUPER::refresh_groups($pi_config);
	if (my $idler = $self->{idler}) {
		$idler->refresh($pi_config);
	}
}

sub idler_start {
	$_[0]->{idler} //= PublicInbox::InboxIdle->new($_[0]->{pi_config});
}

1;
